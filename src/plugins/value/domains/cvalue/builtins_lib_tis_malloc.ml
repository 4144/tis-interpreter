(**************************************************************************)
(*                                                                        *)
(*  This file is part of tis-interpreter.                                 *)
(*  Copyright (C) 2016 CEA                                                *)
(*  Modified by TrustInSoft                                               *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  General Public License as published by the Free Software              *)
(*  Foundation, version 2.                                                *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU General Public License version 2 for more details.                *)
(*  (enclosed in the file licences/GPLv2).                                *)
(*                                                                        *)
(**************************************************************************)

open Cil_types
open Abstract_interp
open Locations
open Cvalue

let dkey = Value_parameters.register_category "malloc"

(** {1 Options} *)

module MallocFunctions=
  Value_parameters.Filled_string_set
    (struct
      let option_name = "-val-malloc-functions"
      let arg_name = "f1,...,fn"
      let help = "The malloc builtins use the call site of malloc() to know \
                  where to create new bases. This detection does not work for \
                  custom allocators or wrappers on top of malloc, unless they \
                  are listed here. By default, only contains malloc."
      let default = Datatype.String.Set.singleton "malloc"
    end)

module MallocReturnsNull=
  Value_parameters.False
    (struct
      let option_name = "-val-malloc-returns-null"
      let help = "The allocation built-ins are modeled as nondeterministically \
                  returning a null pointer"
     end)

module MallocLevel =
  Value_parameters.Int
    (struct
      let option_name = "-val-mlevel"
      let default = 0
      let arg_name = "m"
      let help = "sets to [m] the number of precise dynamic allocation for any \
                  given callstack"
     end)


(** {1 Auxiliary functions} *)

(* Extracts the minimum/maximum sizes (in bytes) for malloc/realloc,
   respecting the bounds of size_t if the information is imprecise.
   Note that the value returned for maximum size corresponds to one past
   the last valid index. *)
let extract_size sizev_bytes =
  try
    let sizei_bytes = Cvalue.V.project_ival sizev_bytes in
    begin match Ival.min_and_max sizei_bytes with
      | Some smin, Some smax ->
        assert (Integer.(ge smin zero));
        smin, smax
      | _ -> assert false (* Cil invariant: cast to size_t *)
    end
  with V.Not_based_on_null ->
    Integer.zero, (Bit_utils.max_byte_size ())

(* Remove some parts of the callstack:
   - Remove the bottom of the call tree until we get to the call site
   of the call to the first malloc function. The idea is that each of
   these call site correspond to a different use of a malloc function,
   so it is interesting to keep their bases separated. *)
let call_stack_no_wrappers () =
  let stack = Value_util.call_stack () in
  assert (stack != []);
  let wrappers = MallocFunctions.get() in
  let rec bottom_filter = function
    | [] -> assert false
    | [_] as stack -> stack (* Do not empty the stack completely *)
    | (kf,_)::((kf', _):: _ as rest) as stack ->
      if Datatype.String.Set.mem (Kernel_function.get_name kf) wrappers then
        if Datatype.String.Set.mem (Kernel_function.get_name kf') wrappers then
          bottom_filter rest
        else
          stack
      else
        stack
  in
  bottom_filter stack
;;

(* Name of the base that will be given to a malloced variable, determined
   using the callstack. *)
let base_name prefix stack =
  let stmt_line stmt = (fst (Cil_datatype.Stmt.loc stmt)).Lexing.pos_lnum in
  match stack with
    | [] -> assert false
    | [kf, Kglobal] -> (* Degenerate case *)
      Pretty_utils.sfprintf "__%s_%a" prefix Kernel_function.pretty kf
    | (_, Kglobal) :: _ :: _ -> assert false
    | (_, Kstmt callsite) :: qstack ->
      (* Use the whole call-stack to generate the name *)
      let rec loop_full = function
        | [_, Kglobal] -> Format.sprintf "_%s" (Kernel.MainFunction.get ())
        | (_, Kglobal) :: _ :: _ -> assert false
        | [] -> assert false (* impossible, we should have seen a Kglobal *)
        | (kf, Kstmt line)::b ->
          let line = stmt_line line in
          let node_str = Pretty_utils.sfprintf "_l%d__%a"
            line Kernel_function.pretty kf
          in
          (loop_full b) ^ node_str
      in
      (* Use only the name of the caller to malloc for the name *)
      let caller = function
        | [] -> assert false (* caught above *)
        | (kf, _) :: _ -> Pretty_utils.sfprintf "_%a" Kernel_function.pretty kf
      in
      let full_name = false in
      Pretty_utils.sfprintf "__%s%s_l%d"
        prefix
        (if full_name then loop_full qstack else caller qstack)
        (stmt_line callsite)
;;

type var = Weak | Strong

let create_new_var stack prefix type_base weak =
  let prefix = match weak with
    | Weak -> prefix ^ "_w"
    | Strong -> prefix
  in
  let name = Cabs2cil.fresh_global (base_name prefix stack) in
  Value_util.create_new_var name type_base

(* This function adds a "_w" information to a variable. It should be used
   when a variable becomes weak, and supposes that the variable has been
   created by one of the functions of this module. Mutating variables name
   is not a good idea in general, but we take the risk here. *)
let mutate_name_to_weak vi =
  Value_parameters.result ~dkey ~current:true ~once:false
    "@[marking variable `%s' as weak@]" vi.vname;
  try
    let prefix, remainder =
      Scanf.sscanf vi.vname "__%s@_%s" (fun s1 s2 -> (s1, s2))
    in
    let name' = Printf.sprintf "__%s_w_%s" prefix remainder in
    vi.vname <- name'
  with End_of_file | Scanf.Scan_failure _ -> ()

(* This type represents the size requested to malloc/realloc and co. *)
type typed_size = {
  min_bytes: Integer.t (* minimum size requested, in bytes *);
  max_bytes: Integer.t (* maximum size requested, in bytes *);
  elem_typ: typ (* "guessed type" for the elements of the new variable *);
  nb_elems: Integer.t option (* number of elements of size [sizeof(elem_typ)].
                                None if [min<>max] *);
}

(* Guess the intended type for the cell returned by malloc, given [sizev ==
   [size_min .. size_max] (in bytes). We look for [T *v = malloc(foo)], then
   check that [size_min] and [size_max] are multiples of [sizeof(T)].
   If no information can be found, we use char for the base type. If the size
   cannot change later ([constant_size]), we also compute the number of
   elements that are allocated. *)
(* TODO: this is not perfect because we can have an overflow in computations
   such as [foo * t = malloc (i * sizeof(foo))] *)
let guess_intended_malloc_type stack sizev constant_size =
  let size_min, size_max = extract_size sizev in
  let nb_elems elem_size =
    if constant_size && Int.equal size_min size_max
    then Some (Int.div size_min elem_size)
    else None
  in
  try
    match snd (List.hd stack) with
    | Kstmt {skind = Instr (Call (Some lv, _, _, _))} -> begin
        match Cil.unrollType (Cil.typeOfLval lv) with
        | TPtr (t, _) when not (Cil.isVoidType t) ->
          let s = Int.of_int (Cil.bytesSizeOf t) in
          if Int.equal (Int.rem size_min s) Int.zero &&
             Int.equal (Int.rem size_max s) Int.zero
          then
            { min_bytes = size_min; max_bytes = size_max; elem_typ = t;
              nb_elems = nb_elems s }
          else raise Exit
        | _ -> raise Exit
      end
    | _ -> raise Exit
  with Exit | Cil.SizeOfError _ -> (* Default, use char *)
    { min_bytes = size_min; max_bytes = size_max; elem_typ = Cil.charType;
      nb_elems = nb_elems Int.one }

(* Helper function to create the best type for a new base.  Builds an
   array type with the appropriate number of elements if needed.  When
   the number of elements cannot be determined, build an array with
   imprecise size. This is not a problem in practice, because in C you
   annot obtain the size of an allocated block, and \block_length
   handles Allocated variables through their validity. *)
let type_from_nb_elems loc tsize =
  let typ = tsize.elem_typ in
  match tsize.nb_elems with
  | None -> TArray (typ, None, Cil.empty_size_cache (), [])
  | Some nb ->
    if Int.equal Int.one nb
    then typ
    else
      let esize_arr = Cil.kinteger64 ~loc nb in (* [nb] fits in size_t *)
      TArray (typ, Some esize_arr, Cil.empty_size_cache (), [])

(* Generalize a type into an array type without size. Useful for variables
   whose size is mutated. *)
let weaken_type typ =
  match Cil.unrollType typ with
  | TArray (_, None, _, _) -> typ
  | TArray (typ, Some _, _, _) | typ ->
    TArray (typ, None, Cil.empty_size_cache (), [])

(* size for which the base is certain to be valid *)
let size_sure_valid b = match Base.validity b with
  | Base.Invalid | Base.Empty | Base.Unknown (_, None, _) -> Integer.zero
  | Base.Known (_, up) | Base.Unknown (_, Some up, _)
  | Base.Variable { Base.min_alloc = up } -> Integer.succ up
;;

(* Create a new offsetmap initialized to [bottom] on the entire allocable
   range, with the first [max_alloc] bits uninitialized. *)
let offsm_with_uninit validity max_alloc =
  let size = Bottom.non_bottom (V_Offsetmap.size_from_validity validity) in
  let offsm = V_Offsetmap.create_isotropic ~size V_Or_Uninitialized.bottom in
  if Int.(lt max_alloc zero) then
    (* malloc(0) => nothing to uninitialize *)
    offsm
  else (* malloc(i > 0) => uninitialize i bytes *)
    begin
      V_Offsetmap.add ~exact:true (Int.zero, max_alloc)
        (V_Or_Uninitialized.uninitialized, Int.one, Rel.zero) offsm
    end

(* add UNINITIALIZED as a possible value for the bits [0..max_valid_bits] of
   [base] in [state] *)
let add_uninitialized state base max_valid_bits =
  let validity = Base.validity base in
  let offsm = offsm_with_uninit validity max_valid_bits in
  let new_offsm =
    try
      let cur = match Model.find_base_or_default base state with
        | `Top -> assert false (* Value nevers passes Top as state *)
        | `Bottom -> assert false (* implicitely checked by offsm_with_uninit *)
        | `Map m -> m
      in
      V_Offsetmap.join offsm cur
    with Not_found -> offsm
  in
  Model.add_base base new_offsm state

let wrap_fallible_malloc ret_base orig_state state_after_alloc =
  let ret = V.inject ret_base Ival.zero in
  let success = Eval_op.wrap_ptr ret, state_after_alloc in
  if MallocReturnsNull.get ()
  then
    (* keep synchronized with headers! *)
    let enomem = Ival.inject_singleton (Int.of_int 75) in
    let failure_state =
      Builtins_lib_tis_aux.optionally_set_errno enomem orig_state
    in
    let failure = Eval_op.wrap_ptr Cvalue.V.singleton_zero, failure_state in
    [ success ; failure ]
  else [ success ]

let pp_validity fmt (v1, v2) =
  if Int.equal v1 v2
  then Format.fprintf fmt "0..%a" Int.pretty v1
  else Format.fprintf fmt "0..%a/%a" Int.pretty v1 Int.pretty v2

(** {1 Malloc} *)

(* Create a new variable of size [sizev], using [stack] to infer a type.
   Returns the new base, and its maximum validity. *)
let alloc_abstract stack loc weak prefix sizev =
  let tsize = guess_intended_malloc_type stack sizev (weak = Strong) in
  let type_base = type_from_nb_elems loc tsize in
  let var = create_new_var stack prefix type_base weak in
  if Value_parameters.ValShowProgress.get () ||
    Value_parameters.ValShowAllocations.get()
  then begin
    Value_parameters.result ~current:true
      "allocating %svariable %a of type %a%t%t"
      (if weak = Weak then "weak " else "")
      Printer.pp_varinfo var
      Printer.pp_typ type_base
    (fun fmt ->
      if tsize.min_bytes <> tsize.max_bytes
      then
        Format.fprintf fmt
          " (between %a and %a bytes)"
          Int.pretty tsize.min_bytes Int.pretty tsize.max_bytes)
      Value_util.pp_callstack
  end;
  let size_char = Bit_utils.sizeofchar () in
  (* Sizes are in bits *)
  let min_alloc = Int.(pred (mul size_char tsize.min_bytes)) in
  let max_alloc = Int.(pred (mul size_char tsize.max_bytes)) in
  (* NOTE: min_alloc/max_alloc may be -1 if the size is zero *)
  assert Int.(ge min_alloc Int.minus_one);
  assert Int.(ge max_alloc min_alloc);
  (* note that min_alloc may be negative (-1) if the allocated size is 0 *)
  let weak = match weak with Weak -> true | Strong -> false in
  let weak_v = Base.create_variable_validity ~weak ~min_alloc ~max_alloc in
  let new_base = Base.register_allocated_var var (Base.Variable weak_v) in
  Value_util.register_malloced_base new_base;
  new_base, max_alloc

let alloc_abstract_highlevel weakness loc prefix sizev state = 
  let stack = call_stack_no_wrappers () in
  let base, max_valid = alloc_abstract stack loc weakness prefix sizev in
  let state = add_uninitialized state base max_valid in
  let allocated =  V.inject base Ival.zero in
  allocated, state
let alloc_abstract_strong = alloc_abstract_highlevel Strong 
  
(* Simplest allocation function: a new base each time, of the required size. *)
let alloc_size weak state actuals =
  match actuals with
  | [exp_size, size, _] ->
    let stack = call_stack_no_wrappers () in
    let loc = exp_size.eloc in
    let base, max_valid = alloc_abstract stack loc weak "malloc" size in
    let new_state = add_uninitialized state base max_valid in
    let c_values = wrap_fallible_malloc base state new_state in
    { Value_types.c_values = c_values ;
      c_clobbered = Base.SetLattice.bottom;
      c_cacheable = Value_types.NoCacheCallers;
      c_from = None(*TODO*)
    }
  | _ -> raise (Builtins.Invalid_nb_of_args 1)

let () = Builtins.register_builtin "Frama_C_alloc_size" (alloc_size Strong)
let () = Builtins.register_builtin "Frama_C_alloc_size_weak" (alloc_size Weak)


(* Variables that have been returned by a call to an allocation function
   at this callstack. The first allocated variable is at the top of the
   stack. Currently, the callstacks are truncated according to
   [-val-malloc-functions]. *)
module MallocedByStack = (* varinfo list Callstack.hashtbl *)
  State_builder.Hashtbl(Value_types.Callstack.Hashtbl)
    (Datatype.List(Base))
    (struct
       let name = "Value.Builtins_lib_malloc.MallocedByStack"
       let size = 17
       let dependencies = [Ast.self]
     end)
let () = Ast.add_monotonic_state MallocedByStack.self

(* Performs an abstract allocation on an existing allocated variable,
   its validity. If [make_weak], the variable is marked as being weak. *)
let update_variable_validity ?(make_weak=false) base sizev =
  let size_min, size_max = extract_size sizev in
  match base with
  | Base.Allocated (vi, (Base.Variable variable_v)) ->
    if make_weak && (variable_v.Base.weak = false) then
      mutate_name_to_weak vi;
    let min_sure_bits = Int.(pred (mul eight size_min)) in
    let max_valid_bits = Int.(pred (mul eight size_max)) in
    if not (Int.equal variable_v.Base.min_alloc min_sure_bits) ||
       not (Int.equal variable_v.Base.max_alloc max_valid_bits)
    then begin
      Value_parameters.result ~dkey ~current:true ~once:false
        "@[resizing variable `%a'@ (%a) to fit %a@]"
        Printer.pp_varinfo vi
        pp_validity (variable_v.Base.min_alloc, variable_v.Base.max_alloc)
        pp_validity (min_sure_bits, max_valid_bits);
      (* Mutating the type of a varinfo is not exactly a good idea. This is
         probably fine here, because the type of a malloced variable is
         almost never used. *)
      vi.vtype <- weaken_type vi.vtype;
    end;
    Base.update_variable_validity variable_v
      ~weak:make_weak ~min_alloc:min_sure_bits ~max_alloc:max_valid_bits;
    base, max_valid_bits
  | _ -> Value_parameters.fatal "base is not Allocated: %a" Base.pretty base

let alloc_by_stack_aux 
    ?(max_level=MallocLevel.get()) initial_weakness 
    loc stack sizev prefix state =
  let all_vars =
    try MallocedByStack.find stack
    with Not_found -> []
  in
  let rec aux nb vars =
    match vars with
    | [] -> (* must allocate a new variable *)
      let b, _ as r = alloc_abstract stack loc initial_weakness prefix sizev in
      MallocedByStack.replace stack (all_vars @ [b]);
      r
    | b :: q ->
      try
        ignore (Model.find_base b state);
        if nb = max_level then begin (* variable already used *)
          update_variable_validity ~make_weak:true b sizev
        end
        else aux (nb+1) q
      with Not_found -> (* Can reuse this (strong) variable *)
        update_variable_validity 
          ~make_weak:(match initial_weakness with
          | Strong -> false
          | Weak -> true)
          b 
          sizev
  in
  aux 0 all_vars

(* For each callstack, the first max_level are precise fresh
   distinct locations. The following allocations all return the same
   base, first strong, then weak, and which is extended as needed. *)
let alloc_by_stack_generic = 
  fun max_level initial_weakness state actuals->
  let stack = call_stack_no_wrappers () in
  let exp_size, sizev = match actuals with
    | [exp,size,_] -> exp, size
    | _ -> raise (Builtins.Invalid_nb_of_args 1)
  in
  let loc = exp_size.eloc in
  let base, max_valid = 
    alloc_by_stack_aux ~max_level
      initial_weakness loc stack sizev "malloc" state 
  in
  let new_state = add_uninitialized state base max_valid in
  let c_values = wrap_fallible_malloc base state new_state in
  { Value_types.c_values = c_values ;
    c_clobbered = Base.SetLattice.bottom;
    c_from = None; (* TODO?*)
    c_cacheable = Value_types.NoCacheCallers }

let () = Builtins.register_builtin "Frama_C_alloc_by_stack" 
  (fun s a -> alloc_by_stack_generic (MallocLevel.get()) Strong s a)


(** {1 Free} *)

(* Change all references to bases into ESCAPINGADDR into the given state,
   and remove thoses bases from the state entirely when [exact] holds *)
let free ~exact bases state =
  (* No need to remove the freed bases from the state if [exact] is false,
     because they must remain for the 'unexact' case *)
  let state =
    if exact then Base.Hptset.fold Cvalue.Model.remove_base bases state
    else state
  in
  let is_the_base_to_free x = Base.Hptset.mem x bases in
  let offsetmap_top_addresses_of_locals =
    Locals_scoping.offsetmap_top_addresses_of_locals is_the_base_to_free
  in
  Locals_scoping.state_top_addresses_of_locals 
    (fun _ _ -> ()) (* no informative message *)
    offsetmap_top_addresses_of_locals ~exact (Locals_scoping.top ())
    state

let resolve_bases_to_free arg =
  (* Categorizes the bases in arg *)
  let f base offset (acc, card, null) =
    let allocated_base = Base.Hptset.mem base (Value_util.malloced_bases ()) in
    (* Does arg contain at least one invalid value? *)
    if (not allocated_base && not (Base.is_null base))
      || Ival.contains_non_zero offset
    then Value_util.warning_once_current
      "Wrong free: assert(pass a freeable address)";
    (* Collect the bases to remove from the memory state.
       Also count the number of freeable bases (including NULL). *)
    if Ival.contains_zero offset
    then begin
      let base_card = match Base.validity base with
        | Base.Variable { Base.weak = true } -> 2
          (* weak validity has "infinite" cardinality; but here we use 2 since
             any value > 1 leads to a weak update anyway *)
        | _ -> 1
      in
      if allocated_base
      then Base.Hptset.add base acc, card + base_card, null
      else if Base.is_null base
      then acc, card + base_card, true
      else acc, card, null
      end
    else acc, card, null
  in
  Cvalue.V.fold_topset_ok f arg (Base.Hptset.empty, 0, false)

let free_aux state ~strong bases_to_remove  =
  (* TODO: reduce on arg if it is an lval *)
  if strong then begin
    Value_parameters.debug ~current:true ~dkey "strong free on bases: %a"
      Base.Hptset.pretty bases_to_remove;
    free ~exact:true bases_to_remove state
  end else begin
    Value_parameters.debug ~current:true ~dkey "weak free on bases: %a"
      Base.Hptset.pretty bases_to_remove;
    free ~exact:false bases_to_remove state
  end

(* Builtin for [free] function *)
let frama_c_free state actuals =
  match actuals with
  | [ _, arg, _ ] ->
    let bases_to_remove, card_to_remove, _null = resolve_bases_to_free arg in
    if card_to_remove = 0 then 
      { Value_types.c_values = [];
        c_clobbered = Base.SetLattice.bottom;
        c_from = None(*TODO*);
        c_cacheable = Value_types.Cacheable; }
    else
      let strong = card_to_remove <= 1 in
      let state = free_aux state ~strong bases_to_remove in
      { Value_types.c_values = [None, state];
        c_clobbered = Base.SetLattice.bottom;
        c_from = None;(*TODO?*)
        c_cacheable = Value_types.Cacheable;
      }
  | _ -> raise (Builtins.Invalid_nb_of_args 1)

let () = Builtins.register_builtin "Frama_C_free" frama_c_free


(** {1 Realloc} *)

(* Auxiliary function for [realloc], that copies the [size] first bytes of
   [b] (or less if [b] is too small) in [src_state], then pastes them in
   [new_base] in [dst_state], which is supposed to be big enough for [size].
   This function always perform weak updates, in case multiple bases are
   copied to [new_base]. *)
let realloc_copy_one size ~src_state ~dst_state new_base b =
  let with_alarms = CilE.warn_none_mode in
  let size_char = Bit_utils.sizeofchar () in
  let size_bits = Integer.mul size size_char in
  let up = match Base.validity b with
    | Base.Known (_, up) | Base.Unknown (_, _, up)
    | Base.Variable { Base.max_alloc = up } -> up
    | Base.Invalid | Base.Empty -> Integer.zero

  in
  let size_to_copy = Int.min (Int.succ up) size_bits in
  let src = Location_Bits.inject b Ival.zero in
  match Eval_op.copy_offsetmap ~with_alarms src size_to_copy src_state with
  | `Bottom | `Top -> assert false
  | `Map offsetmap ->
    if Int.gt size_to_copy Int.zero then
      Eval_op.paste_offsetmap ~reducing:false ~with_alarms
        ~from:offsetmap ~dst_loc:new_base ~size:size_to_copy
        ~exact:false dst_state
    else dst_state

(* Auxiliary function for [realloc], that performs the allocation of a new
   variable, and copy the pointers being reallocated inside the new base.
   [size] is the size to realloc. [bases_to_realloc] are the pointers to the
   memory to copy. [null_in_arg] indicates that [realloc] was called with
   [null] in its argument. [weak] indicates which type of variable must
   be created: if [Weak], convergence is ensured using a malloc builtin
   that converges.  If [Strong], a new base is created for each call. *)
let realloc_alloc_copy loc weak bases_to_realloc null_in_arg sizev state =
  Value_parameters.debug ~dkey "bases_to_realloc: %a"
    Base.Hptset.pretty bases_to_realloc;
  assert (not (Model.(equal state bottom || equal state top)));
  let _size_valid, size_max = extract_size sizev in (* bytes everywhere *)
  let stack = call_stack_no_wrappers () in
  let base, max_valid =
    let prefix = "realloc" in
    match weak with
    | Strong -> alloc_abstract stack loc Strong prefix sizev
    | Weak -> alloc_by_stack_aux Strong loc stack sizev prefix state
  in
  (* Make sure that [ret] will be present in the result: we bind it at least
     to bottom everywhere *)
  let dst_state = add_uninitialized state base Int.minus_one in
  let ret = V.inject base Ival.zero in
  let loc_bits = Locations.loc_bytes_to_loc_bits ret in
  (* get bases to free and copy *)
  let lbases = Base.Hptset.elements bases_to_realloc in
  let dst_state =
    (* unitialized on all reallocated valid bits *)
    let offsm = offsm_with_uninit (Base.validity base) max_valid in
    let offsm =
      if null_in_arg then offsm (* In this case, realloc may copy nothing *)
      else
        (* Compute the maximal size that is guaranteed to be copied accross all
           bases *)
        let aux_valid size b = Integer.min size (size_sure_valid b) in
        let size_new_loc = Integer.mul size_max (Bit_utils.sizeofchar ()) in
        let size_sure_valid = List.fold_left aux_valid size_new_loc lbases in
        (* Replace the bits [0..size_sure_valid] by [bottom]. Those [bottom]
           will be overwritten in the call to [realloc_copy_one]. *)
        if Int.gt size_sure_valid Int.zero then
          V_Offsetmap.add (Int.zero, Int.pred size_sure_valid)
            (V_Or_Uninitialized.bottom, Int.one, Rel.zero) offsm
        else offsm
    in
    Eval_op.paste_offsetmap ~reducing:false ~with_alarms:CilE.warn_none_mode
      ~from:offsm ~dst_loc:loc_bits ~size:(Int.succ max_valid) ~exact:false
     dst_state
  in
  (* Copy the old bases *)
  let copy_one dst_state b =
    realloc_copy_one size_max ~src_state:state ~dst_state loc_bits b
  in
  let state = List.fold_left copy_one dst_state lbases in
  ret, state

(* Auxiliary function for [realloc]. All the bases in [bases] are realloced
   one by one, plus NULL if [null] holds. This function acts as if we had
   first made a disjunction on the pointer passed to [realloc]. *)
let realloc_multiple loc state size bases null =
  (* this function should never be used with weak allocs *)
  let aux_bases b acc = Base.Hptset.singleton b :: acc in
  let lbases = Base.Hptset.fold aux_bases bases [] in
  (* This function reallocates the base [b] alone, but does not free it.
     We cannot free yet, because [b] would leak in the states corresponding
     to the variables different from [b]. *)
  let realloc_one_base b = realloc_alloc_copy loc Strong b false size state in
  let join (ret1, st1) (ret2, st2) = V.join ret1 ret2, Model.join st1 st2 in
  let aux_one_base acc b = join (realloc_one_base b) acc in
  let res = List.fold_left aux_one_base (V.bottom, state) lbases in
  (* Add another base for realloc(NULL) if needed. *)
  if null then
    join res (realloc_alloc_copy loc Strong Base.Hptset.empty true size state)
  else res

(* Multiple indicates that existing bases are reallocateed into as many new
   bases. *)
let realloc ~multiple state args = match args with
  | [ (eptr,ptr,_); (_,size,_) ] ->
    let (bases, card_ok, null) = resolve_bases_to_free ptr in
    if card_ok > 0 then
      let loc = eptr.eloc in
      let ret, state =
        if multiple
        then realloc_multiple loc state size bases null
        else realloc_alloc_copy loc Weak bases null size state
      in
      (* Maybe the calls above made [ret] weak, and it
         was among the arguments. In this case, do not free it entirely! *)
      let weak = Base.Hptset.exists Base.is_weak bases in
      let strong = card_ok <= 1 && not weak in
      (* free old bases. *)
      let state = free_aux state ~strong bases in
      { Value_types.c_values = [Eval_op.wrap_ptr ret, state] ;
        c_clobbered = Builtins.clobbered_set_from_ret state ret;
        c_from = None;(*TODO?*)
        c_cacheable = Value_types.NoCacheCallers;
      }
    else (* Invalid call. *)
      { Value_types.c_values = [] ;
        c_clobbered = Base.SetLattice.bottom;
        c_from = None;
        c_cacheable = Value_types.NoCacheCallers;
      }
  | _ -> raise (Builtins.Invalid_nb_of_args 2)

let () = Builtins.register_builtin "Frama_C_realloc" (realloc ~multiple:false)
let () = Builtins.register_builtin
    "Frama_C_realloc_multiple" (realloc ~multiple:true)


(** {1 Leak detection} *)

(* Experimental, not to be released, leak detection built-in. *)
(* Check if the base_to_check is present in one of 
   the offsetmaps of the state *)
exception Not_leaked
let check_if_base_is_leaked base_to_check state =
  match state with
  | Model.Bottom -> false
  | Model.Top -> true
  | Model.Map m -> 
  try 
    Cvalue.Model.fold 
      (fun base offsetmap () -> 
	if not (Base.equal base_to_check base) then 
	  Cvalue.V_Offsetmap.iter_on_values 
	    (fun v ->
	      if Locations.Location_Bytes.may_reach base_to_check 
		(V_Or_Uninitialized.get_v v) then raise Not_leaked) 
	    offsetmap)
      m
      ();
    true
  with Not_leaked -> false

(* Does not detect leaked cycles within malloc'ed bases.
   The complexity is very far from being optimal. *)
let check_leaked_malloced_bases state _ = 
  let alloced_bases = Value_util.malloced_bases () in
  Base.Hptset.iter 
    (fun base -> if check_if_base_is_leaked base state then 
	Value_util.warning_once_current "memory leak detected for %a"
	  Base.pretty base)
    alloced_bases;
  { Value_types.c_values = [None,state] ;
    c_clobbered = Base.SetLattice.bottom;
    c_from = None (*TODO?*);
    c_cacheable = Value_types.NoCacheCallers;
  }

let () = 
  Builtins.register_builtin "Frama_C_check_leak" check_leaked_malloced_bases

module MallocPrecision=
  Value_parameters.Int
    (struct 
      let option_name = "-val-malloc-plevel" 
      let default=3
      let arg_name = "p"
      let help = "sets to [p] the number of precise dynamic allocation for any \
                  given callstack"
     end)

let alloc_multiple_by_stack : Db.Value.builtin_sig = 
  fun state actuals ->
    alloc_by_stack_generic (MallocPrecision.get ()) Strong state actuals
let () = Builtins.register_builtin "Frama_C_alloc_tms" alloc_multiple_by_stack
let () = Builtins.register_builtin "tis_alloc" alloc_multiple_by_stack
let () = Builtins.register_builtin "tis_alloc_weak" 
  (alloc_by_stack_generic 0 Weak)

(* Variable that has been returned by a call to malloc at this callstack *)
module MallocWeakSize=
  Value_parameters.Int
    (struct 
      let option_name = "-val-tis-alloc-weak-size" 
      let default=10000
      let arg_name = "s"
      let help = "sets the size of the location returned by tis_alloc_weak_legacy to [p] for any given callstack"
     end)

exception Invalid_realloc

let tis_realloc state actuals =
  (* TODO:

     if(c) { r = malloc(sizeof(int)); *r = 12; }
     else { r = malloc(sizeof(int)); *r = 8; }
     p = realloc(r, 2 * sizeof(int));

     On the example above, without slevel,
     the value analysis finds possible uninitialized values
     in the first 32 bits of *p
     whereas they should be marked as always initialized.
     To do: eliminate this approximation. *)
  try
    let esize, size = match actuals with
      | [_; esize,size,_] -> esize, size
      | _ -> raise Invalid_realloc
    in
    let loc = esize.eloc in
    let size = Cvalue.V.project_ival size in
    let size_valid_arr, size_arr =
      ( match Ival.min_and_max size with
	Some size_valid_arr, Some size_arr
	  when Int.ge size_valid_arr Int.zero ->
	    size_valid_arr, size_arr
      | _ -> raise Invalid_realloc )
    in
    (* get bases to free *)
    let old_bases, card, _null = 
      (*TODO: check if this _null is useable *)
      match actuals with
      |	[_,arg,_;_] -> resolve_bases_to_free arg
      | _ -> assert false
    in
    if not (Base.Hptset.mem Base.null old_bases) && Int.is_zero size_arr
    then 
      let state =
        match card with
	  0 -> Model.bottom
        | _ ->
	  let exact = card = 1 in
	  free ~exact old_bases state
      in
      { Value_types.c_values = 
          [Eval_op.wrap_ptr Cvalue.V.singleton_zero, state];
        c_clobbered = Base.SetLattice.bottom;
        c_cacheable = Value_types.NoCacheCallers;
        c_from = None;(*TODO?*)
      }
    else
      let new_loc_bytes, state =
        alloc_abstract_highlevel Strong loc "tis_realloc" 
          (Cvalue.V.inject_ival size) 
          state
      in
      let new_loc_bits = Locations.loc_bytes_to_loc_bits new_loc_bytes in
      let copy_base exact old_base state =
        Base.(match old_base with
        | Var (_,Empty) | Allocated (_, Empty) -> state
        | (Var _ | Allocated _) when Int.is_zero size_arr -> state
        | Var
            (_v, (Known (_l, u)|Unknown (_l, _, u)
                     |Variable {weak=false; min_alloc=_l;max_alloc=u})) 
        | Allocated 
            (_v, (Known (_l, u)|Unknown (_l, _, u)
                     |Variable {weak=false; min_alloc=_l;max_alloc=u}))
          ->
	(* copy old to new. *)
	  let size_char = Bit_utils.sizeofchar () in
	  let size = Integer.mul size_arr size_char in
	  let size_to_copy = Int.min (Int.succ u) size in
	  let old_loc_bits = Location_Bits.inject old_base Ival.zero in
	  ( match Eval_op.copy_offsetmap ~with_alarms:CilE.warn_none_mode
              old_loc_bits size_to_copy state
            with
	    | `Bottom ->
              (* Read failed. Source was invalid, but must be read, we stop the
		 analysis *)
	      raise Invalid_realloc
            | `Top -> Warn.warn_top ();
	    | `Map offsetmap ->
              (* Read succeeded. We write the result *)
              if Int.gt size_to_copy Int.zero then
		Eval_op.paste_offsetmap ~reducing:false 
		  ~with_alarms:CilE.warn_none_mode
		  ~from:offsetmap ~dst_loc:new_loc_bits ~size:size_to_copy
		  ~exact state
              else state )
        | Var (_, Invalid) | Allocated(_,Invalid) | Null -> state
        | Var
            (_v, (Variable {weak=true; min_alloc=_l;max_alloc=_u})) 
        | Allocated 
            (_v, (Variable {weak=true; min_alloc=_l;max_alloc=_u}))
          ->
          Value_parameters.not_yet_implemented 
            "call to realloc on a weak variable (%a)" Base.pretty old_base
        | CLogic_Var (_, _, _) | String (_, _) -> assert false)
      in
    (* free old *)
      let state =
        match card with
	  0 -> Model.bottom
        | _ ->
	  let exact = card = 1 in
	  let state = Base.Hptset.fold (copy_base exact) old_bases state
	  in
	  free ~exact old_bases state
      in
      let can_alloc_bases = Base.Hptset.exists
        (function e -> e = Base.null) old_bases in
      let can_size_zero = Int.is_zero size_valid_arr in
      let result =
        if can_alloc_bases && can_size_zero then
	  Cvalue.V.join Cvalue.V.singleton_zero new_loc_bytes
        else
	  new_loc_bytes
      in
      { Value_types.c_values = [Eval_op.wrap_ptr result, state];
	c_clobbered = Location_Bits.get_bases (loc_bytes_to_loc_bits result);
	c_cacheable = Value_types.NoCacheCallers; 
        c_from = None; (*TODO?*) }
  with Ival.Error_Top | Invalid_realloc | V.Not_based_on_null ->
    Value_parameters.error
      "Invalid argument for tis_realloc function";
    raise Db.Value.Aborted

let () = Builtins.register_builtin "tis_realloc" tis_realloc

(*
Local Variables:
compile-command: "make -C ../../../../.."
End:
*)
