(*
 * Copyright (c) 2015 Luke Dunstan <LukeDunstan81@gmail.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Printf
open Dns.Name
open Dns.Operators
open Dns.Protocol
open Dns_resolver

module DP = Dns.Packet

let default_ns = Ipaddr.V4.of_string_exn "224.0.0.251"
let default_port = 5353

module type S = Dns_resolver_mirage.S

module Make(Time:V1_LWT.TIME)(S:V1_LWT.STACKV4) = struct

  type stack = S.t
  type endp = Ipaddr.V4.t * int

  type t = {
    s: S.t;
    res: (endp, Dns_resolver.commfn) Hashtbl.t;
  }

  let create s =
    let res = Hashtbl.create 3 in
    { s; res }

  let connect_to_resolver {s; res} ((dest_ip,dest_port) as endp) =
    let udp = S.udpv4 s in
    try
      Hashtbl.find res endp
    with Not_found ->
      let timerfn () = Time.sleep 5.0 in
      let mvar = Lwt_mvar.create_empty () in
      let source_port = default_port in
      let callback ~src ~dst ~src_port buf =
        (* TODO: ignore responses that are not from the local link *)
        (* Ignore responses that are not from port 5353 *)
        if src_port == dest_port then
          Lwt_mvar.put mvar buf
        else
          return_unit
      in
      let cleanfn () = return () in
      (* FIXME: can't coexist with server yet because both listen on port 5353 *)
      S.listen_udpv4 s ~port:source_port callback;
      let rec txfn buf =
        Cstruct.of_bigarray buf |>
        S.UDPV4.write ~source_port ~dest_ip ~dest_port udp in
      let rec rxfn f =
        Lwt_mvar.take mvar
        >>= fun buf ->
        match f (Dns.Buf.of_cstruct buf) with
        | None -> rxfn f
        | Some packet -> return packet
      in
      let commfn = { txfn; rxfn; timerfn; cleanfn } in
      Hashtbl.add res endp commfn;
      commfn

  let alloc () = (Io_page.get 1 :> Dns.Buf.t)

  let create_packet q_class q_type q_name =
    let open Dns.Packet in
    let detail = {
      qr=Query; opcode=Standard;
      aa=false; tc=false; rd=false; ra=false; rcode=NoError;
    } in
    let question = { q_name; q_type; q_class; q_unicast=Q_Normal } in
    { id=0; detail; questions=[question];
      answers=[]; authorities=[]; additionals=[];
    }

  let resolve client
      t server dns_port
      (q_class:DP.q_class) (q_type:DP.q_type)
      (q_name:domain_name) =
    let commfn = connect_to_resolver t (server,dns_port) in
    let q = create_packet q_class q_type q_name in
    resolve_pkt ~alloc client commfn q

  let gethostbyname
      t ?(server = default_ns) ?(dns_port = default_port)
      ?(q_class:DP.q_class = DP.Q_IN) ?(q_type:DP.q_type = DP.Q_A)
      name =
    (* TODO: duplicates Dns_resolver.gethostbyname *)
    let open DP in
    let domain = string_to_domain_name name in
    resolve (module Mdns.Protocol.Client) t server dns_port q_class q_type domain
    >|= fun r ->
    List.fold_left (fun a x ->
        match x.rdata with
        | A ip -> Ipaddr.V4 ip :: a
        | AAAA ip -> Ipaddr.V6 ip :: a
        | _ -> a
      ) [] r.answers
    |> List.rev

  let gethostbyaddr
      t ?(server = default_ns) ?(dns_port = default_port)
      ?(q_class:DP.q_class = DP.Q_IN) ?(q_type:DP.q_type = DP.Q_PTR)
      addr =
    (* TODO: duplicates Dns_resolver.gethostbyaddr *)
    let addr = for_reverse addr in
    let open DP in
    resolve (module Mdns.Protocol.Client) t server dns_port q_class q_type addr
    >|= fun r ->
    List.fold_left (fun a x ->
        match x.rdata with |PTR n -> (domain_name_to_string n)::a |_->a
      ) [] r.answers
    |> List.rev

end
