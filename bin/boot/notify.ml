(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(* Strip control characters from every string in the event — member names and
   values alike — so a decoded member cannot smuggle a terminal escape into
   whatever surface the hook writes. *)
let rec strip = function
  | Jsont.String (s, meta) -> Jsont.String (Output.sanitize_c0 s, meta)
  | Jsont.Array (items, meta) -> Jsont.Array (List.map strip items, meta)
  | Jsont.Object (mems, meta) ->
      Jsont.Object
        ( List.map
            (fun ((name, name_meta), value) ->
              ((Output.sanitize_c0 name, name_meta), strip value))
            mems,
          meta )
  | (Jsont.Null _ | Jsont.Bool _ | Jsont.Number _) as json -> json

let fire ~proc_mgr ~clock ~argv ~event =
  match argv with
  | [] -> ()
  | _ :: _ -> (
      match Jsont_bytesrw.encode_string Jsont.json (strip event) with
      | Error _ -> ()
      | Ok line -> (
          (* The switch kills a hook that outlives the timeout: the await is
             cancelled, and releasing the switch SIGKILLs the child. *)
          try
            Eio.Switch.run @@ fun sw ->
            let discard = Eio.Flow.buffer_sink (Buffer.create 256) in
            let child =
              Eio.Process.spawn ~sw proc_mgr
                ~stdin:(Eio.Flow.string_source (line ^ "\n"))
                ~stdout:discard ~stderr:discard argv
            in
            match
              Eio.Time.with_timeout clock 5.0 (fun () ->
                  Ok (Eio.Process.await child))
            with
            | Ok _ | Error `Timeout -> ()
          with
          | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
          | _ -> ()))
