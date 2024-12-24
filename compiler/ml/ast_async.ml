let is_async : Parsetree.attribute -> bool = fun ({txt}, _) -> txt = "res.async"

let has_async_payload attrs = Ext_list.exists attrs is_async

let make_async_attr loc = (Location.mkloc "res.async" loc, Parsetree.PStr [])

let add_async_attribute ~async (body : Parsetree.expression) =
  if async then
    {
      body with
      pexp_attributes =
        ({txt = "res.async"; loc = Location.none}, PStr [])
        :: body.pexp_attributes;
    }
  else body

let extract_async_attribute attrs =
  let rec process async acc attrs =
    match attrs with
    | [] -> (async, List.rev acc)
    | ({Location.txt = "res.async"}, _) :: rest -> process true acc rest
    | attr :: rest -> process async (attr :: acc) rest
  in
  process false [] attrs

let add_promise_type ?(loc = Location.none) ~async
    (result : Parsetree.expression) =
  if async then
    let unsafe_async =
      Ast_helper.Exp.ident ~loc
        {txt = Ldot (Lident Primitive_modules.promise, "unsafe_async"); loc}
    in
    Ast_helper.Exp.apply ~loc unsafe_async [(Nolabel, result)]
  else result

let rec add_promise_to_result ~loc (e : Parsetree.expression) =
  match e.pexp_desc with
  | Pexp_fun f ->
    let rhs = add_promise_to_result ~loc f.rhs in
    {e with pexp_desc = Pexp_fun {f with rhs}}
  | _ -> add_promise_type ~loc ~async:true e

let make_function_async ~async (e : Parsetree.expression) =
  if async then
    match e.pexp_desc with
    | Pexp_fun {lhs = {ppat_loc}} -> add_promise_to_result ~loc:ppat_loc e
    | _ -> assert false
  else e
