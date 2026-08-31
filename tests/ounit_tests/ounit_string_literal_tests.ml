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
      (Parsetree.Pconst_string (encoded, Some "js"))
  in
  match Ast_utf8_string_interp.transform_pat pattern encoded "js" with
  | _ -> OUnit.assert_failure "expected an invalid string escape"
  | exception Location.Error _ -> ()

let assert_invalid_tagged_pattern tag contents =
  let pattern =
    Ast_helper.Pat.constant (Parsetree.Pconst_string (contents, Some tag))
  in
  match Ast_utf8_string_interp.transform_pat pattern contents tag with
  | _ -> OUnit.assert_failure "expected a tagged pattern error"
  | exception Location.Error _ -> ()

let assert_transformed_expression ?(delim = "js") ~encoded ~expected () =
  let expression =
    Ast_helper.Exp.constant (Parsetree.Pconst_string (encoded, Some delim))
  in
  match
    (Ast_utf8_string_interp.transform_exp expression encoded delim).pexp_desc
  with
  | Pexp_constant (Pconst_string (actual, None)) ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected actual
  | _ -> OUnit.assert_failure "expected a semantic string expression"

let assert_transformed_pattern ?(delim = "js") ~encoded ~expected () =
  let pattern =
    Ast_helper.Pat.constant (Parsetree.Pconst_string (encoded, Some delim))
  in
  match
    (Ast_utf8_string_interp.transform_pat pattern encoded delim).ppat_desc
  with
  | Ppat_constant (Pconst_string (actual, None)) ->
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

let typed_string s delim =
  match Typecore.constant (Parsetree.Pconst_string (s, delim)) with
  | Ok constant -> constant
  | Error _ -> OUnit.assert_failure "expected a typed string constant"

let convert_typed_constant constant =
  Lam_constant_convert.convert_constant (Lambda.const_of_typed constant)

let assert_js_string ~expected ~delim constant =
  match (Lam_compile_const.translate constant).J.expression_desc with
  | Str {txt; delim = actual_delim} ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected txt;
    OUnit.assert_equal ~printer:Ext_obj.dump delim actual_delim
  | _ -> OUnit.assert_failure "expected a JavaScript string expression"

let assert_external_js_string ~expected ~delim constant =
  match (Lam_compile_const.translate_arg_cst constant).J.expression_desc with
  | Str {txt; delim = actual_delim} ->
    OUnit.assert_equal ~printer:(Printf.sprintf "%S") expected txt;
    OUnit.assert_equal ~printer:Ext_obj.dump delim actual_delim
  | _ -> OUnit.assert_failure "expected a JavaScript string expression"

let inline_string s delim =
  match Ast_external_mk.inline_string ~loc:Location.none s delim with
  | Prim_inline_const constant -> constant
  | _ -> OUnit.assert_failure "expected an inline constant"

let string_payload s delim =
  Parsetree.PStr
    [
      Ast_helper.Str.eval
        (Ast_helper.Exp.constant (Parsetree.Pconst_string (s, delim)));
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
               (Parsetree.Pconst_string (encoded, Some "js"))
           in
           match
             (Ast_utf8_string_interp.transform_exp expression encoded "js")
               .pexp_desc
           with
           | Pexp_constant (Pconst_string (actual, Some "bq")) ->
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
             Ast_helper.Pat.constant
               (Parsetree.Pconst_string ("a", Some "INTERNAL_RES_CHAR_CONTENTS"))
           in
           let transformed =
             Ast_utf8_string_interp.transform_pat pattern "a"
               "INTERNAL_RES_CHAR_CONTENTS"
           in
           OUnit.assert_equal ~printer:Ext_obj.dump pattern.ppat_desc
             transformed.ppat_desc );
         ( "typed tree separates strings from template segments" >:: fun _ ->
           let semantic = typed_string "a\n😀" None in
           let template = typed_string {|a\n\uD83D\uDE00|} (Some "bq") in
           let json = typed_string {|{"answer":42}|} (Some "json") in
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_string "a\n😀") semantic;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_template_segment {|a\n\uD83D\uDE00|}) template;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Asttypes.Const_string {|{"answer":42}|}) json;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Parsetree.Pconst_string ("a\n😀", None))
             (Untypeast.constant semantic);
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Parsetree.Pconst_string ({|a\n\uD83D\uDE00|}, Some "bq"))
             (Untypeast.constant template) );
         ( "constant backquoted attribute strings become semantic" >:: fun _ ->
           OUnit.assert_equal ~printer:Ext_obj.dump (Some "a\n😀")
             (Ast_payload.is_single_semantic_string
                (string_payload {|\x61\n\uD83D\uDE00|} (Some "bq")));
           OUnit.assert_equal ~printer:Ext_obj.dump None
             (Ast_payload.is_single_semantic_string
                (string_payload {|{"answer":42}|} (Some "json")));
           match
             Ast_payload.is_single_semantic_string
               (string_payload {|\uD800|} (Some "bq"))
           with
           | _ -> OUnit.assert_failure "expected an invalid string escape"
           | exception Location.Error _ -> () );
         ( "external string constants have explicit representations" >:: fun _ ->
           OUnit.assert_equal ~printer:Ext_obj.dump
             (External_ffi_types.Const_string "a\n😀")
             (inline_string {|\x61\n\uD83D\uDE00|} (Some "bq"));
           OUnit.assert_equal ~printer:Ext_obj.dump
             (External_ffi_types.Const_json {|{"answer":42}|})
             (inline_string {|{"answer":42}|} (Some "json"));
           assert_external_js_string ~expected:{|\x61|} ~delim:J.DNone
             (External_arg_spec.cst_string {|\x61|});
           assert_external_js_string ~expected:{|{"answer":42}|}
             ~delim:J.DNoQuotes
             (External_arg_spec.cst_json {|{"answer":42}|});
           match inline_string {|\uD800|} (Some "bq") with
           | _ -> OUnit.assert_failure "expected an invalid string escape"
           | exception Location.Error _ -> () );
         ( "Lambda separates strings from template segments" >:: fun _ ->
           let semantic =
             convert_typed_constant (Asttypes.Const_string "a\n😀")
           in
           let template =
             convert_typed_constant
               (Asttypes.Const_template_segment {|a\n\uD83D\uDE00|})
           in
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Lam_constant.Const_string "a\n😀") semantic;
           OUnit.assert_equal ~printer:Ext_obj.dump
             (Lam_constant.Const_template_segment {|a\n\uD83D\uDE00|}) template;
           OUnit.assert_bool "semantic and template strings stay distinct"
             (not
                (Lam_constant.eq_approx (Lam_constant.Const_string {|a\n|})
                   (Lam_constant.Const_template_segment {|a\n|}))) );
         ( "Lambda string kinds lower differently" >:: fun _ ->
           assert_js_string ~expected:"a\n😀" ~delim:J.DNone
             (Lam_constant.Const_string "a\n😀");
           assert_js_string ~expected:{|a\n\uD83D\uDE00|} ~delim:J.DBackQuotes
             (Lam_constant.Const_template_segment {|a\n\uD83D\uDE00|}) );
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
