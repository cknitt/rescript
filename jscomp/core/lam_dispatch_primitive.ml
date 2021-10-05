(* Copyright (C) 2015 - 2016 Bloomberg Finance L.P.
 * Copyright (C) 2017 - Hongbo Zhang, Authors of ReScript 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

module E = Js_exp_make
(* module S = Js_stmt_make *)

(** 
   There are two things we need consider:
   1.  For some primitives we can replace caml-primitive with js primitives directly
   2.  For some standard library functions, we prefer to replace with javascript primitives
    For example [Pervasives["^"] -> ^]
    We can collect all mli files in OCaml and replace it with an efficient javascript runtime

   TODO: return type to be expression is ugly, 
   we should allow return block    
*)
let translate loc (prim_name : string) (args : J.expression list) : J.expression
    =
  let[@inline] call ?name m =
    let name =
      match name with
      | None ->
          if prim_name.[0] = '?' then
            String.sub prim_name 1 (String.length prim_name - 1)
          else if Ext_string.starts_with prim_name "caml_" then
            String.sub prim_name 5 (String.length prim_name - 5)
          else assert false (* prim_name *)
      | Some x -> x
    in
    E.runtime_call m name args
  in
  match prim_name with
  | "caml_notequal" -> (
      match args with
      | [ a1; b1 ]
        when E.for_sure_js_null_undefined a1 || E.for_sure_js_null_undefined b1
        ->
          E.neq_null_undefined_boolean a1 b1
      (* FIXME address_equal *)
      | _ ->
          Location.prerr_warning loc Warnings.Bs_polymorphic_comparison;
          call Js_runtime_modules.obj_runtime)
  | "caml_equal" -> (
      match args with
      | [ a1; b1 ]
        when E.for_sure_js_null_undefined a1 || E.for_sure_js_null_undefined b1
        ->
          E.eq_null_undefined_boolean a1 b1
      (* FIXME address_equal *)
      | _ ->
          Location.prerr_warning loc Warnings.Bs_polymorphic_comparison;
          call Js_runtime_modules.obj_runtime)
  | "caml_min" | "caml_max" | "caml_compare" | "caml_greaterequal"
  | "caml_greaterthan" | "caml_lessequal" | "caml_lessthan" | "caml_equal_null"
  | "caml_equal_undefined" | "caml_equal_nullable" ->
      Location.prerr_warning loc Warnings.Bs_polymorphic_comparison;
      call Js_runtime_modules.obj_runtime
  (* generated by the compiler, not user facing *)
  | "caml_bytes_greaterthan" | "caml_bytes_greaterequal" | "caml_bytes_lessthan"
  | "caml_bytes_lessequal" | "caml_bytes_compare" | "caml_bytes_equal" ->
      call Js_runtime_modules.bytes
  | "caml_string_equal" -> (
      match args with [ e0; e1 ] -> E.string_equal e0 e1 | _ -> assert false)
  | "caml_string_notequal" -> (
      match args with
      | [ e0; e1 ] -> E.string_comp NotEqEq e0 e1
      (* TODO: convert to ocaml ones*)
      | _ -> assert false)
  | "caml_string_lessequal" -> (
      match args with [ e0; e1 ] -> E.string_comp Le e0 e1 | _ -> assert false)
  | "caml_string_lessthan" -> (
      match args with [ e0; e1 ] -> E.string_comp Lt e0 e1 | _ -> assert false)
  | "caml_string_greaterequal" -> (
      match args with [ e0; e1 ] -> E.string_comp Ge e0 e1 | _ -> assert false)
  | "caml_int64_equal_null" -> Js_long.equal_null args
  | "caml_int64_equal_undefined" -> Js_long.equal_undefined args
  | "caml_int64_equal_nullable" -> Js_long.equal_nullable args
  | "caml_int64_min" -> Js_long.min args
  | "caml_int64_max" -> Js_long.max args
  | "caml_int64_compare" -> Js_long.compare args
  | "caml_string_greaterthan" -> (
      match args with [ e0; e1 ] -> E.string_comp Gt e0 e1 | _ -> assert false)
  | "caml_bool_notequal" -> (
      match args with
      | [ e0; e1 ] -> E.bool_comp Cneq e0 e1
      (* TODO: specialized in OCaml ones*)
      | _ -> assert false)
  | "caml_bool_lessequal" -> (
      match args with [ e0; e1 ] -> E.bool_comp Cle e0 e1 | _ -> assert false)
  | "caml_bool_lessthan" -> (
      match args with [ e0; e1 ] -> E.bool_comp Clt e0 e1 | _ -> assert false)
  | "caml_bool_greaterequal" -> (
      match args with [ e0; e1 ] -> E.bool_comp Cge e0 e1 | _ -> assert false)
  | "caml_bool_greaterthan" -> (
      match args with [ e0; e1 ] -> E.bool_comp Cgt e0 e1 | _ -> assert false)
  | "caml_bool_equal" | "caml_bool_equal_null" | "caml_bool_equal_nullable"
  | "caml_bool_equal_undefined" -> (
      match args with [ e0; e1 ] -> E.bool_comp Ceq e0 e1 | _ -> assert false)
  | "caml_int_equal_null" | "caml_int_equal_nullable"
  | "caml_int_equal_undefined" -> (
      match args with [ e0; e1 ] -> E.int_comp Ceq e0 e1 | _ -> assert false)
  | "caml_float_equal_null" | "caml_float_equal_nullable"
  | "caml_float_equal_undefined" -> (
      match args with [ e0; e1 ] -> E.float_comp Ceq e0 e1 | _ -> assert false)
  | "caml_string_equal_null" | "caml_string_equal_nullable"
  | "caml_string_equal_undefined" -> (
      match args with
      | [ e0; e1 ] -> E.string_comp EqEqEq e0 e1
      | _ -> assert false)
  | "caml_bool_compare" -> (
      match args with
      | [ { expression_desc = Bool a }; { expression_desc = Bool b } ] ->
          let c = compare (a : bool) b in
          E.int (if c = 0 then 0l else if c > 0 then 1l else -1l)
      | _ -> call Js_runtime_modules.caml_primitive)
  | "caml_int_compare" ->
      E.runtime_call Js_runtime_modules.caml_primitive "int_compare" args
  | "caml_float_compare" -> call Js_runtime_modules.caml_primitive
  | "caml_string_compare" -> call Js_runtime_modules.caml_primitive
  | "caml_bool_min" | "caml_int_min" | "caml_float_min" | "caml_string_min" -> (
      match args with
      | [ a; b ] ->
          if
            Js_analyzer.is_okay_to_duplicate a
            && Js_analyzer.is_okay_to_duplicate b
          then E.econd (E.js_comp Clt a b) a b
          else call Js_runtime_modules.caml_primitive
      | _ -> assert false)
  | "caml_bool_max" | "caml_int_max" | "caml_float_max" | "caml_string_max" -> (
      match args with
      | [ a; b ] ->
          if
            Js_analyzer.is_okay_to_duplicate a
            && Js_analyzer.is_okay_to_duplicate b
          then E.econd (E.js_comp Cgt a b) a b
          else call Js_runtime_modules.caml_primitive
      | _ -> assert false)
  (******************************************************************************)
  (************************* customized primitives ******************************)
  (******************************************************************************)
  | "?int_of_float" -> (
      match args with [ e ] -> E.to_int32 e | _ -> assert false)
  | "?int64_succ" -> E.runtime_call Js_runtime_modules.int64 "succ" args
  | "?int64_to_string" ->
      E.runtime_call Js_runtime_modules.int64 "to_string" args
  | "?int64_to_float" -> Js_long.to_float args
  | "?int64_of_float" -> Js_long.of_float args
  | "?int64_bits_of_float" -> Js_long.bits_of_float args
  | "?int64_float_of_bits" -> Js_long.float_of_bits args
  | "?int_float_of_bits" | "?int_bits_of_float" | "?modf_float" | "?ldexp_float"
  | "?frexp_float" | "?copysign_float" | "?expm1_float" | "?hypot_float" ->
      call Js_runtime_modules.float
  | "?fmod_float" (* float module like js number module *) -> (
      match args with [ e0; e1 ] -> E.float_mod e0 e1 | _ -> assert false)
  | "?string_repeat" -> (
      match args with
      | [ n; { expression_desc = Number (Int { i }) } ] -> (
          let str = String.make 1 (Char.chr (Int32.to_int i)) in
          match n.expression_desc with
          | Number (Int { i = 1l }) -> E.str str
          | _ ->
              E.call
                (E.dot (E.str str) "repeat")
                [ n ] ~info:Js_call_info.builtin_runtime_call)
      | _ -> E.runtime_call Js_runtime_modules.string "make" args)
  | "?create_bytes" -> (
      (* Bytes.create *)
      (* Note that for invalid range, JS raise an Exception RangeError,
         here in OCaml it's [Invalid_argument], we have to preserve this semantics.
          Also, it's creating a [bytes] which is a js array actually.
      *)
      match args with
      | [ { expression_desc = Number (Int { i; _ }); _ } ] when i < 8l ->
          (*Invariants: assuming bytes are [int array]*)
          E.array NA
            (if i = 0l then []
            else Ext_list.init (Int32.to_int i) (fun _ -> E.zero_int_literal))
      | _ -> E.runtime_call Js_runtime_modules.bytes "create" args)
  (* Note we captured [exception/extension] creation in the early pass, this primitive is
      like normal one to set the identifier *)
  | "?exn_slot_name" | "?is_extension" -> call Js_runtime_modules.exceptions
  | "?as_js_exn" -> call Js_runtime_modules.caml_js_exceptions
  | "?sys_get_argv" | "?sys_file_exists" | "?sys_time" | "?sys_getenv"
  | "?sys_getcwd" (* check browser or nodejs *)
  | "?sys_is_directory" | "?sys_exit" ->
      call Js_runtime_modules.sys
  | "?lex_engine" | "?new_lex_engine" -> call Js_runtime_modules.lexer
  | "?parse_engine" | "?set_parser_trace" -> call Js_runtime_modules.parser
  | "?make_float_vect"
  | "?floatarray_create" (* TODO: compile float array into TypedArray*) ->
      E.runtime_call Js_runtime_modules.array "make_float" args
  | "?array_sub" -> E.runtime_call Js_runtime_modules.array "sub" args
  | "?array_concat" -> E.runtime_call Js_runtime_modules.array "concat" args
  (*external concat: 'a array list -> 'a array
     Not good for inline *)
  | "?array_blit" -> E.runtime_call Js_runtime_modules.array "blit" args
  | "?make_vect" -> E.runtime_call Js_runtime_modules.array "make" args
  | "?format_float" | "?hexstring_of_float" | "?float_of_string"
  | "?int_of_string" (* what is the semantics?*)
  | "?int64_format" | "?int64_of_string" | "?format_int" ->
      call Js_runtime_modules.format
  | "?obj_dup" -> call Js_runtime_modules.obj_runtime
  | "?obj_tag" -> (
      (* Note that in ocaml, [int] has tag [1000] and [string] has tag [252]
         also now we need do nullary check
      *)
      match args with [ e ] -> E.tag e | _ -> assert false)
  | "?md5_string" -> call Js_runtime_modules.md5
  | "?hash_mix_string" | "?hash_mix_int" | "?hash_final_mix" ->
      call Js_runtime_modules.hash_primitive
  | "?hash" -> call Js_runtime_modules.hash
  | "?nativeint_add" -> (
      match args with
      | [ e1; e2 ] -> E.unchecked_int32_add e1 e2
      | _ -> assert false)
  | "?nativeint_div" -> (
      match args with
      | [ e1; e2 ] -> E.int32_div e1 e2 ~checked:false
      | _ -> assert false)
  | "?nativeint_mod" -> (
      match args with
      | [ e1; e2 ] -> E.int32_mod e1 e2 ~checked:false
      | _ -> assert false)
  | "?nativeint_lsr" -> (
      match args with [ e1; e2 ] -> E.int32_lsr e1 e2 | _ -> assert false)
  | "?nativeint_mul" -> (
      match args with
      | [ e1; e2 ] -> E.unchecked_int32_mul e1 e2
      | _ -> assert false)
  | _ ->
      Bs_warnings.warn_missing_primitive loc prim_name;
      E.resolve_and_apply prim_name args
(*we dont use [throw] here, since [throw] is an statement
  so we wrap in IIFE
  TODO: we might provoide a hook for user to provide polyfill.
  For example `Bs_global.xxx`
*)
