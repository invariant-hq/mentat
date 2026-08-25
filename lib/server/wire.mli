(*---------------------------------------------------------------------------
  Copyright (c) 2026 Invariant Systems. All rights reserved.
  SPDX-License-Identifier: ISC
 ---------------------------------------------------------------------------*)

(** The request/response envelope and the SSE frame vocabulary. The
    endpoint-specific payload and result cross as generic JSON subtrees, decoded
    against the resolved descriptor's codec by the dispatcher and the remote
    driver. *)

val version : int
(** [version] is the envelope version floor: [1]. *)

(** {1:envelopes Envelopes} *)

type request = {
  request_id : string option;
      (** Present only for a flow whose replay is not already safe. *)
  endpoint : string;  (** The stable wire name of one descriptor. *)
  payload : Jsont.json;  (** The endpoint's request, as a generic subtree. *)
}

val request_jsont : request Jsont.t

type response = {
  resp_request_id : string option;
  outcome : (Jsont.json, Mentat_protocol.Error.t) result;
      (** [Ok] carries the endpoint's result subtree; [Error] the one protocol
          error type. *)
}

val response_jsont : response Jsont.t

type handshake_request = {
  v_max : int;
  requested_workspace : string option;
  environment : (string * string) list option;
      (** The invoking client's process environment, offered on every handshake;
          the daemon resolves a freshly booted workspace instance against it so
          confined commands are configured from the shell that asked for the
          run, not the shell that spawned the daemon. [None] is a client that
          offers none; the daemon falls back to its own. A full environment is
          tens of kilobytes and rides every handshake — any dial may be the one
          that re-boots an evicted instance — which the local socket absorbs;
          the server's request-size bound caps abuse. *)
}
(** [requested_workspace] is the client's canonical workspace root to bind this
    connection to (the one-connection-one-workspace binding); [None] leaves it
    unbound. *)

val handshake_request_jsont : handshake_request Jsont.t

type handshake_response = { negotiated : int; workspace : string option }
(** [workspace] is the daemon's canonically-bound root, echoed so a client can
    refuse a wrong-checkout attach; [None] when the connection is unbound. *)

val handshake_response_jsont : handshake_response Jsont.t

(** {1:bridges String and generic-JSON bridges} *)

val decode : 'a Jsont.t -> string -> ('a, string) result

val encode : 'a Jsont.t -> 'a -> string
(** [encode] raises [Invalid_argument] only on an owner value its codec rejects
    — a programming error, not a wire condition. *)

val decode_json : 'a Jsont.t -> Jsont.json -> ('a, string) result
val encode_json : 'a Jsont.t -> 'a -> Jsont.json
