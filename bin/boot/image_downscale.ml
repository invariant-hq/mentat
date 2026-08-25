(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

module Image = Mentat_llm.Image

let write_temp bytes =
  let path = Filename.temp_file "mentat-img-in-" "" in
  Out_channel.with_open_bin path (fun oc -> Out_channel.output_string oc bytes);
  path

(* Bytes scale with pixel count, which scales with the square of the longest
   side; a 0.9 safety margin undershoots the target so a single resize usually
   lands under the cap. *)
let target_dimension ~bytes ~target_bytes =
  match Image.dimensions bytes with
  | None -> None
  | Some { Image.width; height } ->
      let longest = max width height in
      let ratio =
        float_of_int target_bytes /. float_of_int (String.length bytes)
      in
      let scale = sqrt (ratio *. 0.9) in
      let dim = int_of_float (float_of_int longest *. scale) in
      Some (max 1 (min longest dim))

(* True iff [argv] runs and exits zero; stdout and stderr are discarded, and a
   missing executable or any failure is a clean [false]. *)
let run_ok process_mgr argv =
  try
    let discard = Buffer.create 64 in
    ignore
      (Eio.Process.parse_out process_mgr Eio.Buf_read.take_all
         ~stderr:(Eio.Flow.buffer_sink discard)
         argv);
    true
  with _ -> false

let run ~stdenv ~bytes ~target_bytes =
  match target_dimension ~bytes ~target_bytes with
  | None -> None
  | Some dim ->
      let process_mgr = Eio.Stdenv.process_mgr stdenv in
      let in_path = write_temp bytes in
      let out_path = Filename.temp_file "mentat-img-out-" "" in
      let cleanup () =
        (try Sys.remove in_path with _ -> ());
        try Sys.remove out_path with _ -> ()
      in
      Fun.protect ~finally:cleanup @@ fun () ->
      let geometry = Printf.sprintf "%dx%d>" dim dim in
      let attempts =
        [
          [ "sips"; "-Z"; string_of_int dim; in_path; "--out"; out_path ];
          [ "magick"; in_path; "-resize"; geometry; out_path ];
          [ "convert"; in_path; "-resize"; geometry; out_path ];
        ]
      in
      let rec try_tools = function
        | [] -> None
        | argv :: rest ->
            if run_ok process_mgr argv then
              match
                try
                  Some (In_channel.with_open_bin out_path In_channel.input_all)
                with _ -> None
              with
              | Some out
                when String.length out > 0
                     && String.length out < String.length bytes
                     && Option.is_some (Image.sniff out) ->
                  Some out
              | _ -> try_tools rest
            else try_tools rest
      in
      try_tools attempts
