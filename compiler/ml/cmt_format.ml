include Cmt_format_common

let set_args = Cmt_format_persistence.set_args

let save_cmt filename modname binary_annots sourcefile initial_env =
  Perf_timer.time "save_cmt" @@ fun () ->
  Cmt_format_persistence.save_cmt filename modname binary_annots sourcefile
    initial_env;
  clear ()
