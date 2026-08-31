let ( >:: ), ( >::: ) = OUnit.(( >:: ), ( >::: ))

let assert_decoded ~encoded ~expected =
  OUnit.assert_equal ~printer:Ext_obj.dump (Some expected)
    (String_literal.decode_js_escapes encoded)

let assert_invalid_backquoted_pattern encoded =
  let template_attribute =
    (Location.mknoloc "res.template", Parsetree.PStr [])
  in
  let pattern =
    Ast_helper.Pat.constant ~attrs:[template_attribute]
      (Parsetree.Pconst_unprocessed_string encoded)
  in
  match Ast_utf8_string_interp.transform_pat pattern encoded with
  | _ -> OUnit.assert_failure "expected an invalid string escape"
  | exception Location.Error _ -> ()

let assert_invalid_tagged_pattern tag contents =
  let pattern =
    Ast_helper.Pat.constant
      (Parsetree.Pconst_tagged_string {tag; source = contents})
  in
  match Bs_builtin_ppx.mapper.pat Bs_builtin_ppx.mapper pattern with
  | _ -> OUnit.assert_failure "expected a tagged pattern error"
  | exception Location.Error _ -> ()

let assert_transformed_expression ~encoded ~expected () =
  let expression =
    Ast_helper.Exp.constant (Parsetree.Pconst_unprocessed_string encoded)
  in
  match (Ast_utf8_string_interp.transform_exp expression encoded).pexp_desc with
  | Pexp_constant (Pconst_string actual) ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a semantic string expression"

let assert_transformed_pattern ~encoded ~expected () =
  let pattern =
    Ast_helper.Pat.constant (Parsetree.Pconst_unprocessed_string encoded)
  in
  match (Ast_utf8_string_interp.transform_pat pattern encoded).ppat_desc with
  | Ppat_constant (Pconst_string actual) ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a semantic string pattern"

let assert_int_equal expected actual =
  OUnit.assert_equal ~printer:string_of_int expected actual

let assert_code_point_at string index expected =
  OUnit.assert_equal ~printer:Ext_obj.dump expected
    (String_literal.code_point_at_utf16_index string index)

let semantic_string s = Lam.const (Lam_constant.Const_string s)

let lam_int i = Lam.const (Lam_constant.Const_int (Int32.of_int i))

let assert_lam_int expected = function
  | Lam.Lconst (Lam_constant.Const_int i) ->
    OUnit.assert_equal ~printer:Int32.to_string (Int32.of_int expected) i
  | _ -> OUnit.assert_failure "expected a folded Lambda integer"

let assert_lam_char expected = function
  | Lam.Lconst (Lam_constant.Const_char actual) ->
    assert_int_equal expected actual
  | _ -> OUnit.assert_failure "expected a folded Lambda character"

let typed_string s =
  match Typecore.constant (Parsetree.Pconst_string s) with
  | Ok constant -> constant
  | Error _ -> OUnit.assert_failure "expected a typed string constant"

let typed_template source =
  match Typecore.constant (Parsetree.Pconst_template source) with
  | Ok constant -> constant
  | Error _ -> OUnit.assert_failure "expected a typed template constant"

let typed_json source =
  match Typecore.constant (Parsetree.Pconst_json source) with
  | Ok constant -> constant
  | Error _ -> OUnit.assert_failure "expected a typed JSON-tagged string"

let convert_typed_constant constant =
  Lam_constant_convert.convert_constant (Lambda.const_of_typed constant)

let assert_js_string ~expected constant =
  match (Lam_compile_const.translate constant).J.expression_desc with
  | Str actual ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a JavaScript string expression"

let assert_external_js_string ~expected constant =
  match (Lam_compile_const.translate_arg_cst constant).J.expression_desc with
  | Str actual ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a JavaScript string expression"

let assert_js_template_literal ~expected_source ~expected_semantic constant =
  match (Lam_compile_const.translate constant).J.expression_desc with
  | Template_literal {source; semantic} ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected_source source;
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected_semantic semantic
  | _ -> OUnit.assert_failure "expected a JavaScript template literal"

let assert_external_json_literal ~expected constant =
  match (Lam_compile_const.translate_arg_cst constant).J.expression_desc with
  | Json_literal actual ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a JavaScript JSON literal expression"

let inline_string constant =
  match Ast_external_mk.inline_string ~loc:Location.none constant with
  | Prim_inline_const constant -> constant
  | _ -> OUnit.assert_failure "expected an inline constant"

let inline_template source =
  match
    Ast_external_mk.inline_string ~loc:Location.none
      (Parsetree.Pconst_template source)
  with
  | Prim_inline_const constant -> constant
  | _ -> OUnit.assert_failure "expected an inline constant"

let assert_js_global ~expected (expression : J.expression) =
  match expression.expression_desc with
  | Var (Id ident) ->
    OUnit.assert_bool "expected a JavaScript global" (Ext_ident.is_js ident);
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected ident.name
  | _ -> OUnit.assert_failure "expected a JavaScript global reference"

let string_payload constant =
  Parsetree.PStr [Ast_helper.Str.eval (Ast_helper.Exp.constant constant)]

let template_payload source =
  Parsetree.PStr
    [
      Ast_helper.Str.eval
        (Ast_helper.Exp.constant (Parsetree.Pconst_template source));
    ]

let suites =
  __FILE__
  >::: [
         ( "plain text" >:: fun _ ->
           assert_decoded ~encoded:"plain" ~expected:"plain" );
         ( "named escapes" >:: fun _ ->
           assert_decoded ~encoded:{|\b\f\n\r\t\v\0|}
             ~expected:"\b\012\n\r\t\011\000" );
         ( "escaped punctuation and non-escapes" >:: fun _ ->
           assert_decoded ~encoded:{|\\\"\'\ \$\`\a|} ~expected:{|\"' $`a|};
           assert_decoded ~encoded:"\\é" ~expected:"é" );
         ( "hex escapes" >:: fun _ ->
           assert_decoded ~encoded:{|\x61\xE9|} ~expected:"aé" );
         ( "unicode escapes" >:: fun _ ->
           assert_decoded ~encoded:{|\u0061\u20AC|} ~expected:"a€";
           assert_decoded ~encoded:{|\u{1f600}|} ~expected:"😀";
           assert_decoded ~encoded:{|\uD83D\uDE00|} ~expected:"😀" );
         ( "line continuations" >:: fun _ ->
           assert_decoded ~encoded:"a\\\nb" ~expected:"ab";
           assert_decoded ~encoded:"a\\\rb" ~expected:"ab";
           assert_decoded ~encoded:"a\\\r\nb" ~expected:"ab" );
         ( "ordinary literals become semantic strings" >:: fun _ ->
           assert_transformed_expression ~encoded:{|\x61\n\uD83D\uDE00|}
             ~expected:"a\n😀" ();
           assert_transformed_pattern ~encoded:{|\x61\n\uD83D\uDE00|}
             ~expected:"a\n😀" () );
         ( "template literals remain raw" >:: fun _ ->
           let encoded = {|\x61|} in
           let template_attribute =
             (Location.mknoloc "res.template", Parsetree.PStr [])
           in
           let expression =
             Ast_helper.Exp.constant ~attrs:[template_attribute]
               (Parsetree.Pconst_template encoded)
           in
           match
             (Bs_builtin_ppx.mapper.expr Bs_builtin_ppx.mapper expression)
               .pexp_desc
           with
           | Pexp_constant (Pconst_template actual) ->
             OUnit.assert_equal ~printer:(Printf.sprintf "%S") encoded actual
           | _ -> OUnit.assert_failure "expected a raw template segment" );
         ( "invalid encoded values are rejected" >:: fun _ ->
           List.iter
             (fun encoded ->
               OUnit.assert_equal ~printer:Ext_obj.dump None
                 (String_literal.decode_js_escapes encoded))
             [
               {|trailing\|};
               {|\x6|};
               {|\xGG|};
               {|\u061|};
               {|\u{}|};
               {|\u{110000}|};
               {|\uD800|};
               {|\uDC00|};
               {|\uD800\u0041|};
               {|\uDC00\uD800|};
               "\128";
               "\195";
               "\195A";
               "\\\195";
             ] );
         ( "backquoted patterns reject lone surrogate escapes" >:: fun _ ->
           assert_invalid_backquoted_pattern {|\uD800|};
           assert_invalid_backquoted_pattern {|\uDC00|} );
         ( "patterns reject tagged template literals" >:: fun _ ->
           (* A tagged pattern cannot invoke its tag. Treating its raw contents as
              a string made json`\x61` collide with the ordinary "\\x61"
              pattern during string-switch sorting. *)
           assert_invalid_tagged_pattern "json" {|\x61|} );
         ( "printer char patterns are not tagged templates" >:: fun _ ->
           let pattern =
             Ast_helper.Pat.constant (Parsetree.Pconst_char_source "a")
           in
           let transformed =
             Bs_builtin_ppx.mapper.pat Bs_builtin_ppx.mapper pattern
           in
           OUnit.assert_equal ~printer:Ext_obj.dump pattern.ppat_desc
             transformed.ppat_desc );
         ( "typed tree separates strings from template literals" >:: fun _ ->
           let semantic = typed_string "a\n😀" in
           let template = typed_template {|a\n\uD83D\uDE00|} in
           let json = typed_json {|{"answer":42}|} in
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_string "a\n😀") semantic;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_template_literal
                {source = {|a\n\uD83D\uDE00|}; semantic = "a\n😀"})
             template;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_string {|{"answer":42}|}) json;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Parsetree.Pconst_string "a\n😀")
             (Untypeast.constant semantic);
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Parsetree.Pconst_template {|a\n\uD83D\uDE00|})
             (Untypeast.constant template);
           match Typecore.constant (Parsetree.Pconst_template {|\unicode|}) with
           | Error Typecore.Invalid_string_escape_sequence -> ()
           | _ ->
             OUnit.assert_failure "expected an invalid ordinary template escape"
         );
         ( "constant backquoted attribute strings become semantic" >:: fun _ ->
           OUnit.assert_equal ~printer:Ext_obj.dump (Some "a\n😀")
             (Ast_payload.is_single_semantic_string
                (template_payload {|\x61\n\uD83D\uDE00|}));
           OUnit.assert_equal ~printer:Ext_obj.dump None
             (Ast_payload.is_single_semantic_string
                (string_payload (Pconst_json {|{"answer":42}|})));
           match
             Ast_payload.is_single_semantic_string (template_payload {|\uD800|})
           with
           | _ -> OUnit.assert_failure "expected an invalid string escape"
           | exception Location.Error _ -> () );
         ( "external string constants have explicit representations" >:: fun _ ->
           OUnit.assert_equal ~printer:Ext_obj.dump
             (External_ffi_types.Const_string "a\n😀")
             (inline_template {|\x61\n\uD83D\uDE00|});
           OUnit.assert_equal ~printer:Ext_obj.dump
             (External_ffi_types.Const_json {|{"answer":42}|})
             (inline_string (Pconst_json {|{"answer":42}|}));
           assert_external_js_string ~expected:{|\x61|}
             (External_arg_spec.cst_string {|\x61|});
           assert_external_json_literal ~expected:{|{"answer":42}|}
             (External_arg_spec.cst_json {|{"answer":42}|});
           let json = Js_exp_make.json_literal {| {answer: 42} |} in
           OUnit.assert_bool "expected JSON literals to be side-effect free"
             (Js_analyzer.no_side_effect_expression json);
           OUnit.assert_bool
             "expected allocating JSON literals not to duplicate"
             (not (Js_analyzer.is_okay_to_duplicate json));
           OUnit.assert_bool "expected JSON literals not to compare as strings"
             (not
                (Js_analyzer.eq_expression json
                   (Js_exp_make.json_literal {| {answer: 42} |})));
           (match (Js_exp_make.typeof json).expression_desc with
           | Typeof argument ->
             OUnit.assert_bool "expected typeof to preserve the JSON expression"
               (json == argument)
           | _ -> OUnit.assert_failure "expected a runtime typeof expression");
           OUnit.assert_equal ~printer:(Printf.sprintf "%S") {| {answer: 42} |}
             (Js_dump.string_of_expression json);
           match inline_template {|\uD800|} with
           | _ -> OUnit.assert_failure "expected an invalid string escape"
           | exception Location.Error _ -> () );
         ( "Lambda separates strings from template literals" >:: fun _ ->
           let semantic =
             convert_typed_constant (Asttypes.Const_string "a\n😀")
           in
           let template =
             Lam_constant_convert.convert_constant
               (Lambda.Const_template_literal
                  {source = {|a\n\uD83D\uDE00|}; semantic = "a\n😀"})
           in
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Lam_constant.Const_string "a\n😀") semantic;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Lam_constant.Const_template_literal
                {source = {|a\n\uD83D\uDE00|}; semantic = "a\n😀"})
             template;
           OUnit.assert_bool "semantic and template strings stay distinct"
             (not
                (Lam_constant.eq_approx (Lam_constant.Const_string {|a\n|})
                   (Lam_constant.Const_template_literal
                      {source = {|a\n|}; semantic = "a\n"}))) );
         ( "Lambda string kinds lower differently" >:: fun _ ->
           assert_js_string ~expected:"a\n😀" (Lam_constant.Const_string "a\n😀");
           assert_js_template_literal ~expected_source:{|a\n\uD83D\uDE00|}
             ~expected_semantic:"a\n😀"
             (Lam_constant.Const_template_literal
                {source = {|a\n\uD83D\uDE00|}; semantic = "a\n😀"});
           let semantic = Js_exp_make.str "a" in
           let template = Js_exp_make.template_literal ~semantic:"a" {|\x61|} in
           OUnit.assert_equal ~printer:(Printf.sprintf "%S") {|`\x61`|}
             (Js_dump.string_of_expression template);
           (match (Js_exp_make.string_length template).expression_desc with
           | Number (Int {i = 1l}) -> ()
           | _ ->
             OUnit.assert_failure
               "expected template literal length to use its semantic value");
           (match
              (Js_exp_make.string_append semantic template).expression_desc
            with
           | String_append _ -> ()
           | _ ->
             OUnit.assert_failure
               "expected semantic strings and template segments not to fold");
           (match
              (Js_exp_make.string_append template
                 (Js_exp_make.template_literal ~semantic:"b" "b"))
                .expression_desc
            with
           | String_append _ -> ()
           | _ ->
             OUnit.assert_failure
               "expected template literals not to merge their source text");
           let tagged =
             Js_exp_make.tagged_template
               (Js_exp_make.js_global "tag")
               [{|a\n|}; " b"]
               [Js_exp_make.small_int 1]
           in
           (match tagged.expression_desc with
           | Tagged_template (_, segments, [_]) ->
             OUnit.assert_equal ~printer:Ext_obj.dump [{|a\n|}; " b"] segments
           | _ ->
             OUnit.assert_failure
               "expected tagged templates to own their encoded segments");
           OUnit.assert_equal ~printer:(Printf.sprintf "%S") {|tag`a\n${1} b`|}
             (Js_dump.string_of_expression tagged) );
         ( "JavaScript references are not encoded as strings" >:: fun _ ->
           let value = Js_exp_make.var (Ext_ident.create "value") in
           (match (Js_exp_make.is_array value).expression_desc with
           | Call
               ( {expression_desc = Static_index (array, "isArray", None)},
                 [argument],
                 _ ) ->
             assert_js_global ~expected:"Array" array;
             OUnit.assert_bool "expected the original argument"
               (Js_analyzer.eq_expression value argument)
           | _ -> OUnit.assert_failure "expected an Array.isArray call");
           (match
              Js_exp_make.and_
                (Js_exp_make.is_array value)
                (Js_exp_make.triple_equal value (Js_exp_make.str "literal"))
            with
           | {expression_desc = Bool false} -> ()
           | _ ->
             OUnit.assert_failure
               "expected Array.isArray simplification to remain active");
           let open Ast_untagged_variants.Dynamic_checks in
           let date = Variant_runtime.Instance.Date in
           assert_js_global ~expected:"Date"
             (Js_exp_make.emit_check
                (TagType (Variant_runtime.Untagged (InstanceType date))));
           match Js_exp_make.emit_check (IsInstanceOf (date, Expr value)) with
           | {expression_desc = Bin (InstanceOf, argument, constructor)} ->
             OUnit.assert_bool "expected the original argument"
               (Js_analyzer.eq_expression value argument);
             assert_js_global ~expected:"Date" constructor
           | _ -> OUnit.assert_failure "expected an instanceof expression" );
         ( "UTF-16 length" >:: fun _ ->
           assert_int_equal 0 (String_literal.utf16_length "");
           assert_int_equal 3 (String_literal.utf16_length "abc");
           assert_int_equal 1 (String_literal.utf16_length "é");
           assert_int_equal 2 (String_literal.utf16_length "😀");
           assert_int_equal 4 (String_literal.utf16_length "a😀b") );
         ( "codePointAt with UTF-16 indices" >:: fun _ ->
           assert_code_point_at "a😀b" (-1) None;
           assert_code_point_at "a😀b" 0 (Some 0x61);
           assert_code_point_at "a😀b" 1 (Some 0x1f600);
           assert_code_point_at "a😀b" 2 (Some 0xde00);
           assert_code_point_at "a😀b" 3 (Some 0x62);
           assert_code_point_at "a😀b" 4 None );
         ( "Lambda string length uses UTF-16 units" >:: fun _ ->
           Lam.prim ~primitive:Lam_primitive.Pstringlength
             ~args:[semantic_string "a😀b"]
             Location.none
           |> assert_lam_int 4 );
         ( "Lambda string indexing uses codePointAt semantics" >:: fun _ ->
           Lam.prim ~primitive:Lam_primitive.Pstringrefs
             ~args:[semantic_string "a😀b"; lam_int 1]
             Location.none
           |> assert_lam_char 0x1f600;
           Lam.prim ~primitive:Lam_primitive.Pstringrefu
             ~args:[semantic_string "a😀b"; lam_int 2]
             Location.none
           |> assert_lam_char 0xde00 );
         ( "JS string length uses UTF-16 units" >:: fun _ ->
           match
             (Js_exp_make.string_length (Js_exp_make.str "a😀b")).expression_desc
           with
           | J.Number (Js_op.Int {i}) ->
             OUnit.assert_equal ~printer:Int32.to_string 4l i
           | _ -> OUnit.assert_failure "expected a folded JavaScript integer" );
       ]
