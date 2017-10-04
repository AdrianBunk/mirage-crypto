open Sexplib.Conv
open Uncommon

exception Invalid_public_key

type group = {
  p  : Z.t        ;  (* The prime modulus *)
  gg : Z.t        ;  (* Group generator *)
  q  : Z.t option ;  (* `gg`'s order, maybe *)
} [@@deriving sexp]

type secret = { x : Z.t } [@@deriving sexp]

(*
 * Estimates of equivalent-strength exponent sizes for the moduli sizes.
 * 2048-8192 are taken from "Negotiated FF DHE Parameters for TLS."
 * Sizes above and below are further guesswork.
 *)
let exp_equivalent = [
  (1024, 180); (2048, 225); (3072, 275); (4096, 325); (6144, 375); (8192, 400)
]
and exp_equivalent_max = 512

let exp_size bits =
  try snd @@ List.find (fun (g, _) -> g >= bits) exp_equivalent
  with Not_found -> exp_equivalent_max

let modulus_size { p; _ } = Numeric.Z.bits p

(*
 * Current thinking:
 * g^y < 0 || g^y >= p : obviously not computed mod p
 * g^y = 0 || g^y = 1  : shared secret is 0, resp. 1
 * g^y = p - 1         : order of g^y is 2
 * g^y = g             : y mod (p-1) is 1
 *)
let bad_public_key { p; gg; _ } ggx =
  ggx <= Z.one || ggx >= Z.(pred p) || ggx = gg

let key_of_secret_z ({ p; gg; _ } as group) x =
  match Z.(powm gg x p) with
  | ggx when bad_public_key group ggx
        -> raise Invalid_public_key
  | ggx -> ({ x }, Numeric.Z.to_cstruct_be ggx)

let key_of_secret group ~s =
  key_of_secret_z group (Numeric.Z.of_cstruct_be s)

(* XXX
 * - slightly weird distribution when bits > |q|
 * - exponentiation time
 *)
let rec gen_key ?g ?bits ({ p; q; _ } as group) =
  let pb = Numeric.Z.bits p in
  let s = Option.(
    min (getf exp_size pb bits)
        (q >>| Numeric.Z.bits |> get ~def:pb))
    |> Rng.Z.gen_bits ?g ~msb:1 in
  try key_of_secret_z group s
  with Invalid_public_key -> gen_key ?g group

(* No time-masking. Does it matter in case of ephemeral DH??  *)
let shared ({ p; _ } as group) { x } cs =
  match Numeric.Z.of_cstruct_be cs with
  | ggy when bad_public_key group ggy -> None
  | ggy -> Some (Numeric.Z.to_cstruct_be (Z.powm ggy x p))

(* Finds a safe prime with [p = 2q + 1] and [2^q = 1 mod p]. *)
let rec gen_group ?g bits =
  if bits < 8 then invalid_arg "Dh.gen_group: group size %d" bits;
  let gg     = Z.two
  and (q, p) = Rng.safe_prime ?g bits in
  if Z.(powm gg q p = one) then { p; gg; q = Some q } else gen_group ?g bits

module Group = struct

  let f z = Numeric.Z.of_cstruct_be (Cs.of_hex z)

  (* Safe-prime-style group: p = 2q + 1 && gg = 2 && gg^q = 1 mod p *)
  let s_group ~p =
    let p = f p in
    { p; gg = Z.(~$2); q = Some Z.(pred p / ~$2) }

  (* Any old group. *)
  let group ~p ~gg ~q =
    { p = f p; gg = f gg; q = Some (f q) }


  (* RFC2409 *)

  let oakley_1 =
    (* 2^768 - 2 ^704 - 1 + 2^64 * { [2^638 pi] + 149686 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A63A3620 FFFFFFFF FFFFFFFF"

  let oakley_2 =
    (* 2^1024 - 2^960 - 1 + 2^64 * { [2^894 pi] + 129093 }. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE65381
       FFFFFFFF FFFFFFFF"


  (* RFC3526 *)

  let oakley_5 =
    (* 2^1536 - 2^1472 - 1 + 2^64 * { [2^1406 pi] + 741804 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA237327 FFFFFFFF FFFFFFFF"

  let oakley_14 =
    (* 2^2048 - 2^1984 - 1 + 2^64 * { [2^1918 pi] + 124476 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
       E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
       DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
       15728E5A 8AACAA68 FFFFFFFF FFFFFFFF"

  let oakley_15 =
    (* 2^3072 - 2^3008 - 1 + 2^64 * { [2^2942 pi] + 1690314 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
       E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
       DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
       15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
       ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
       ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
       F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
       BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
       43DB5BFC E0FD108E 4B82D120 A93AD2CA FFFFFFFF FFFFFFFF"

  let oakley_16 =
    (* 2^4096 - 2^4032 - 1 + 2^64 * { [2^3966 pi] + 240904 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
       E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
       DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
       15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
       ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
       ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
       F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
       BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
       43DB5BFC E0FD108E 4B82D120 A9210801 1A723C12 A787E6D7
       88719A10 BDBA5B26 99C32718 6AF4E23C 1A946834 B6150BDA
       2583E9CA 2AD44CE8 DBBBC2DB 04DE8EF9 2E8EFC14 1FBECAA6
       287C5947 4E6BC05D 99B2964F A090C3A2 233BA186 515BE7ED
       1F612970 CEE2D7AF B81BDD76 2170481C D0069127 D5B05AA9
       93B4EA98 8D8FDDC1 86FFB7DC 90A6C08F 4DF435C9 34063199
       FFFFFFFF FFFFFFFF"

  let oakley_17 =
    (* 2^6144 - 2^6080 - 1 + 2^64 * { [2^6014 pi] + 929484 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
       E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
       DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
       15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
       ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
       ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
       F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
       BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
       43DB5BFC E0FD108E 4B82D120 A9210801 1A723C12 A787E6D7
       88719A10 BDBA5B26 99C32718 6AF4E23C 1A946834 B6150BDA
       2583E9CA 2AD44CE8 DBBBC2DB 04DE8EF9 2E8EFC14 1FBECAA6
       287C5947 4E6BC05D 99B2964F A090C3A2 233BA186 515BE7ED
       1F612970 CEE2D7AF B81BDD76 2170481C D0069127 D5B05AA9
       93B4EA98 8D8FDDC1 86FFB7DC 90A6C08F 4DF435C9 34028492
       36C3FAB4 D27C7026 C1D4DCB2 602646DE C9751E76 3DBA37BD
       F8FF9406 AD9E530E E5DB382F 413001AE B06A53ED 9027D831
       179727B0 865A8918 DA3EDBEB CF9B14ED 44CE6CBA CED4BB1B
       DB7F1447 E6CC254B 33205151 2BD7AF42 6FB8F401 378CD2BF
       5983CA01 C64B92EC F032EA15 D1721D03 F482D7CE 6E74FEF6
       D55E702F 46980C82 B5A84031 900B1C9E 59E7C97F BEC7E8F3
       23A97A7E 36CC88BE 0F1D45B7 FF585AC5 4BD407B2 2B4154AA
       CC8F6D7E BF48E1D8 14CC5ED2 0F8037E0 A79715EE F29BE328
       06A1D58B B7C5DA76 F550AA3D 8A1FBFF0 EB19CCB1 A313D55C
       DA56C9EC 2EF29632 387FE8D7 6E3C0468 043E8F66 3F4860EE
       12BF2D5B 0B7474D6 E694F91E 6DCC4024 FFFFFFFF FFFFFFFF"

  let oakley_18 =
    (* 2^8192 - 2^8128 - 1 + 2^64 * { [2^8062 pi] + 4743158 } *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
       29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
       EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
       E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
       EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
       C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
       83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
       670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
       E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
       DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
       15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
       ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
       ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
       F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
       BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
       43DB5BFC E0FD108E 4B82D120 A9210801 1A723C12 A787E6D7
       88719A10 BDBA5B26 99C32718 6AF4E23C 1A946834 B6150BDA
       2583E9CA 2AD44CE8 DBBBC2DB 04DE8EF9 2E8EFC14 1FBECAA6
       287C5947 4E6BC05D 99B2964F A090C3A2 233BA186 515BE7ED
       1F612970 CEE2D7AF B81BDD76 2170481C D0069127 D5B05AA9
       93B4EA98 8D8FDDC1 86FFB7DC 90A6C08F 4DF435C9 34028492
       36C3FAB4 D27C7026 C1D4DCB2 602646DE C9751E76 3DBA37BD
       F8FF9406 AD9E530E E5DB382F 413001AE B06A53ED 9027D831
       179727B0 865A8918 DA3EDBEB CF9B14ED 44CE6CBA CED4BB1B
       DB7F1447 E6CC254B 33205151 2BD7AF42 6FB8F401 378CD2BF
       5983CA01 C64B92EC F032EA15 D1721D03 F482D7CE 6E74FEF6
       D55E702F 46980C82 B5A84031 900B1C9E 59E7C97F BEC7E8F3
       23A97A7E 36CC88BE 0F1D45B7 FF585AC5 4BD407B2 2B4154AA
       CC8F6D7E BF48E1D8 14CC5ED2 0F8037E0 A79715EE F29BE328
       06A1D58B B7C5DA76 F550AA3D 8A1FBFF0 EB19CCB1 A313D55C
       DA56C9EC 2EF29632 387FE8D7 6E3C0468 043E8F66 3F4860EE
       12BF2D5B 0B7474D6 E694F91E 6DBE1159 74A3926F 12FEE5E4
       38777CB6 A932DF8C D8BEC4D0 73B931BA 3BC832B6 8D9DD300
       741FA7BF 8AFC47ED 2576F693 6BA42466 3AAB639C 5AE4F568
       3423B474 2BF1C978 238F16CB E39D652D E3FDB8BE FC848AD9
       22222E04 A4037C07 13EB57A8 1A23F0C7 3473FC64 6CEA306B
       4BCBC886 2F8385DD FA9D4B7F A2C087E8 79683303 ED5BDD3A
       062B3CF5 B3A278A6 6D2A13F8 3F44F82D DF310EE0 74AB6A36
       4597E899 A0255DC1 64F31CC5 0846851D F9AB4819 5DED7EA1
       B1D510BD 7EE74D73 FAF36BC3 1ECFA268 359046F4 EB879F92
       4009438B 481C6CD7 889A002E D5EE382B C9190DA6 FC026E47
       9558E447 5677E9AA 9E3050E2 765694DF C81F56E8 80B96E71
       60C980DD 98EDD3DF FFFFFFFF FFFFFFFF"


  (* RFC5114 *)

  (* 1024-bit, 160-bit subgroup *)
  let rfc_5114_1 =
    let p =
      "B10B8F96 A080E01D DE92DE5E AE5D54EC 52C99FBC FB06A3C6
       9A6A9DCA 52D23B61 6073E286 75A23D18 9838EF1E 2EE652C0
       13ECB4AE A9061123 24975C3C D49B83BF ACCBDD7D 90C4BD70
       98488E9C 219A7372 4EFFD6FA E5644738 FAA31A4F F55BCCC0
       A151AF5F 0DC8B4BD 45BF37DF 365C1A65 E68CFDA7 6D4DA708
       DF1FB2BC 2E4A4371"
    and gg =
      "A4D1CBD5 C3FD3412 6765A442 EFB99905 F8104DD2 58AC507F
       D6406CFF 14266D31 266FEA1E 5C41564B 777E690F 5504F213
       160217B4 B01B886A 5E91547F 9E2749F4 D7FBD7D3 B9A92EE1
       909D0D22 63F80A76 A6A24C08 7A091F53 1DBF0A01 69B6A28A
       D662A4D1 8E73AFA3 2D779D59 18D08BC8 858F4DCE F97C2A24
       855E6EEB 22B3B2E5"
    and q = "F518AA87 81A8DF27 8ABA4E7D 64B7CB9D 49462353"
    in
    group ~p ~gg ~q

  (* 2048-bit, 224-bit subgroup *)
  let rfc_5114_2 =
    let p =
      "AD107E1E 9123A9D0 D660FAA7 9559C51F A20D64E5 683B9FD1
       B54B1597 B61D0A75 E6FA141D F95A56DB AF9A3C40 7BA1DF15
       EB3D688A 309C180E 1DE6B85A 1274A0A6 6D3F8152 AD6AC212
       9037C9ED EFDA4DF8 D91E8FEF 55B7394B 7AD5B7D0 B6C12207
       C9F98D11 ED34DBF6 C6BA0B2C 8BBC27BE 6A00E0A0 B9C49708
       B3BF8A31 70918836 81286130 BC8985DB 1602E714 415D9330
       278273C7 DE31EFDC 7310F712 1FD5A074 15987D9A DC0A486D
       CDF93ACC 44328387 315D75E1 98C641A4 80CD86A1 B9E587E8
       BE60E69C C928B2B9 C52172E4 13042E9B 23F10B0E 16E79763
       C9B53DCF 4BA80A29 E3FB73C1 6B8E75B9 7EF363E2 FFA31F71
       CF9DE538 4E71B81C 0AC4DFFE 0C10E64F"
    and gg =
      "AC4032EF 4F2D9AE3 9DF30B5C 8FFDAC50 6CDEBE7B 89998CAF
       74866A08 CFE4FFE3 A6824A4E 10B9A6F0 DD921F01 A70C4AFA
       AB739D77 00C29F52 C57DB17C 620A8652 BE5E9001 A8D66AD7
       C1766910 1999024A F4D02727 5AC1348B B8A762D0 521BC98A
       E2471504 22EA1ED4 09939D54 DA7460CD B5F6C6B2 50717CBE
       F180EB34 118E98D1 19529A45 D6F83456 6E3025E3 16A330EF
       BB77A86F 0C1AB15B 051AE3D4 28C8F8AC B70A8137 150B8EEB
       10E183ED D19963DD D9E263E4 770589EF 6AA21E7F 5F2FF381
       B539CCE3 409D13CD 566AFBB4 8D6C0191 81E1BCFE 94B30269
       EDFE72FE 9B6AA4BD 7B5A0F1C 71CFFF4C 19C418E1 F6EC0179
       81BC087F 2A7065B3 84B890D3 191F2BFA"
    and q =
      "801C0D34 C58D93FE 99717710 1F80535A 4738CEBC BF389A99
       B36371EB"
    in
    group ~p ~gg ~q

  (* 2048-bit, 256-bit subgroup *)
  let rfc_5114_3 =
    let p =
      "87A8E61D B4B6663C FFBBD19C 65195999 8CEEF608 660DD0F2
       5D2CEED4 435E3B00 E00DF8F1 D61957D4 FAF7DF45 61B2AA30
       16C3D911 34096FAA 3BF4296D 830E9A7C 209E0C64 97517ABD
       5A8A9D30 6BCF67ED 91F9E672 5B4758C0 22E0B1EF 4275BF7B
       6C5BFC11 D45F9088 B941F54E B1E59BB8 BC39A0BF 12307F5C
       4FDB70C5 81B23F76 B63ACAE1 CAA6B790 2D525267 35488A0E
       F13C6D9A 51BFA4AB 3AD83477 96524D8E F6A167B5 A41825D9
       67E144E5 14056425 1CCACB83 E6B486F6 B3CA3F79 71506026
       C0B857F6 89962856 DED4010A BD0BE621 C3A3960A 54E710C3
       75F26375 D7014103 A4B54330 C198AF12 6116D227 6E11715F
       693877FA D7EF09CA DB094AE9 1E1A1597"
    and gg =
      "3FB32C9B 73134D0B 2E775066 60EDBD48 4CA7B18F 21EF2054
       07F4793A 1A0BA125 10DBC150 77BE463F FF4FED4A AC0BB555
       BE3A6C1B 0C6B47B1 BC3773BF 7E8C6F62 901228F8 C28CBB18
       A55AE313 41000A65 0196F931 C77A57F2 DDF463E5 E9EC144B
       777DE62A AAB8A862 8AC376D2 82D6ED38 64E67982 428EBC83
       1D14348F 6F2F9193 B5045AF2 767164E1 DFC967C1 FB3F2E55
       A4BD1BFF E83B9C80 D052B985 D182EA0A DB2A3B73 13D3FE14
       C8484B1E 052588B9 B7D2BBD2 DF016199 ECD06E15 57CD0915
       B3353BBB 64E0EC37 7FD02837 0DF92B52 C7891428 CDC67EB6
       184B523D 1DB246C3 2F630784 90F00EF8 D647D148 D4795451
       5E2327CF EF98C582 664B4C0F 6CC41659"
    and q =
      "8CF83642 A709A097 B4479976 40129DA2 99B1A47D 1EB3750B
       A308B0FE 64F5FBD3"
    in
    group ~p ~gg ~q


  (* draft-ietf-tls-negotiated-ff-dhe-08 *)

  let ffdhe2048 =
    (* p = 2^2048 - 2^1984 + {[2^1918 * e] + 560316 } * 2^64 - 1 *)
    (* The estimated symmetric-equivalent strength of this group is 103 bits.

       Peers using ffdhe2048 that want to optimize their key exchange with a
       short exponent (Section 5.2) should choose a secret key of at least
       225 bits. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF ADF85458 A2BB4A9A AFDC5620 273D3CF1
       D8B9C583 CE2D3695 A9E13641 146433FB CC939DCE 249B3EF9
       7D2FE363 630C75D8 F681B202 AEC4617A D3DF1ED5 D5FD6561
       2433F51F 5F066ED0 85636555 3DED1AF3 B557135E 7F57C935
       984F0C70 E0E68B77 E2A689DA F3EFE872 1DF158A1 36ADE735
       30ACCA4F 483A797A BC0AB182 B324FB61 D108A94B B2C8E3FB
       B96ADAB7 60D7F468 1D4F42A3 DE394DF4 AE56EDE7 6372BB19
       0B07A7C8 EE0A6D70 9E02FCE1 CDF7E2EC C03404CD 28342F61
       9172FE9C E98583FF 8E4F1232 EEF28183 C3FE3B1B 4C6FAD73
       3BB5FCBC 2EC22005 C58EF183 7D1683B2 C6F34A26 C1B2EFFA
       886B4238 61285C97 FFFFFFFF FFFFFFFF"


  let ffdhe3072 =
    (* p = 2^3072 - 2^3008 + {[2^2942 * e] + 2625351} * 2^64 -1 *)
    (* The estimated symmetric-equivalent strength of this group is 125 bits.

       Peers using ffdhe3072 that want to optimize their key exchange with a
       short exponent (Section 5.2) should choose a secret key of at least
       275 bits. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF ADF85458 A2BB4A9A AFDC5620 273D3CF1
       D8B9C583 CE2D3695 A9E13641 146433FB CC939DCE 249B3EF9
       7D2FE363 630C75D8 F681B202 AEC4617A D3DF1ED5 D5FD6561
       2433F51F 5F066ED0 85636555 3DED1AF3 B557135E 7F57C935
       984F0C70 E0E68B77 E2A689DA F3EFE872 1DF158A1 36ADE735
       30ACCA4F 483A797A BC0AB182 B324FB61 D108A94B B2C8E3FB
       B96ADAB7 60D7F468 1D4F42A3 DE394DF4 AE56EDE7 6372BB19
       0B07A7C8 EE0A6D70 9E02FCE1 CDF7E2EC C03404CD 28342F61
       9172FE9C E98583FF 8E4F1232 EEF28183 C3FE3B1B 4C6FAD73
       3BB5FCBC 2EC22005 C58EF183 7D1683B2 C6F34A26 C1B2EFFA
       886B4238 611FCFDC DE355B3B 6519035B BC34F4DE F99C0238
       61B46FC9 D6E6C907 7AD91D26 91F7F7EE 598CB0FA C186D91C
       AEFE1309 85139270 B4130C93 BC437944 F4FD4452 E2D74DD3
       64F2E21E 71F54BFF 5CAE82AB 9C9DF69E E86D2BC5 22363A0D
       ABC52197 9B0DEADA 1DBF9A42 D5C4484E 0ABCD06B FA53DDEF
       3C1B20EE 3FD59D7C 25E41D2B 66C62E37 FFFFFFFF FFFFFFFF"

  let ffdhe4096 =
    (* p = 2^4096 - 2^4032 + {[2^3966 * e] + 5736041} * 2^64 - 1 *)
    (* The estimated symmetric-equivalent strength of this group is 150 bits.

       Peers using ffdhe4096 that want to optimize their key exchange with a
       short exponent (Section 5.2) should choose a secret key of at least
       325 bits. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF ADF85458 A2BB4A9A AFDC5620 273D3CF1
       D8B9C583 CE2D3695 A9E13641 146433FB CC939DCE 249B3EF9
       7D2FE363 630C75D8 F681B202 AEC4617A D3DF1ED5 D5FD6561
       2433F51F 5F066ED0 85636555 3DED1AF3 B557135E 7F57C935
       984F0C70 E0E68B77 E2A689DA F3EFE872 1DF158A1 36ADE735
       30ACCA4F 483A797A BC0AB182 B324FB61 D108A94B B2C8E3FB
       B96ADAB7 60D7F468 1D4F42A3 DE394DF4 AE56EDE7 6372BB19
       0B07A7C8 EE0A6D70 9E02FCE1 CDF7E2EC C03404CD 28342F61
       9172FE9C E98583FF 8E4F1232 EEF28183 C3FE3B1B 4C6FAD73
       3BB5FCBC 2EC22005 C58EF183 7D1683B2 C6F34A26 C1B2EFFA
       886B4238 611FCFDC DE355B3B 6519035B BC34F4DE F99C0238
       61B46FC9 D6E6C907 7AD91D26 91F7F7EE 598CB0FA C186D91C
       AEFE1309 85139270 B4130C93 BC437944 F4FD4452 E2D74DD3
       64F2E21E 71F54BFF 5CAE82AB 9C9DF69E E86D2BC5 22363A0D
       ABC52197 9B0DEADA 1DBF9A42 D5C4484E 0ABCD06B FA53DDEF
       3C1B20EE 3FD59D7C 25E41D2B 669E1EF1 6E6F52C3 164DF4FB
       7930E9E4 E58857B6 AC7D5F42 D69F6D18 7763CF1D 55034004
       87F55BA5 7E31CC7A 7135C886 EFB4318A ED6A1E01 2D9E6832
       A907600A 918130C4 6DC778F9 71AD0038 092999A3 33CB8B7A
       1A1DB93D 7140003C 2A4ECEA9 F98D0ACC 0A8291CD CEC97DCF
       8EC9B55A 7F88A46B 4DB5A851 F44182E1 C68A007E 5E655F6A
       FFFFFFFF FFFFFFFF"

  let ffdhe6144 =
    (* p = 2^6144 - 2^6080 + {[2^6014 * e] + 15705020} * 2^64 - 1 *)
    (* The estimated symmetric-equivalent strength of this group is 175 bits.

       Peers using ffdhe6144 that want to optimize their key exchange with a
       short exponent (Section 5.2) should choose a secret key of at least
       375 bits. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF ADF85458 A2BB4A9A AFDC5620 273D3CF1
       D8B9C583 CE2D3695 A9E13641 146433FB CC939DCE 249B3EF9
       7D2FE363 630C75D8 F681B202 AEC4617A D3DF1ED5 D5FD6561
       2433F51F 5F066ED0 85636555 3DED1AF3 B557135E 7F57C935
       984F0C70 E0E68B77 E2A689DA F3EFE872 1DF158A1 36ADE735
       30ACCA4F 483A797A BC0AB182 B324FB61 D108A94B B2C8E3FB
       B96ADAB7 60D7F468 1D4F42A3 DE394DF4 AE56EDE7 6372BB19
       0B07A7C8 EE0A6D70 9E02FCE1 CDF7E2EC C03404CD 28342F61
       9172FE9C E98583FF 8E4F1232 EEF28183 C3FE3B1B 4C6FAD73
       3BB5FCBC 2EC22005 C58EF183 7D1683B2 C6F34A26 C1B2EFFA
       886B4238 611FCFDC DE355B3B 6519035B BC34F4DE F99C0238
       61B46FC9 D6E6C907 7AD91D26 91F7F7EE 598CB0FA C186D91C
       AEFE1309 85139270 B4130C93 BC437944 F4FD4452 E2D74DD3
       64F2E21E 71F54BFF 5CAE82AB 9C9DF69E E86D2BC5 22363A0D
       ABC52197 9B0DEADA 1DBF9A42 D5C4484E 0ABCD06B FA53DDEF
       3C1B20EE 3FD59D7C 25E41D2B 669E1EF1 6E6F52C3 164DF4FB
       7930E9E4 E58857B6 AC7D5F42 D69F6D18 7763CF1D 55034004
       87F55BA5 7E31CC7A 7135C886 EFB4318A ED6A1E01 2D9E6832
       A907600A 918130C4 6DC778F9 71AD0038 092999A3 33CB8B7A
       1A1DB93D 7140003C 2A4ECEA9 F98D0ACC 0A8291CD CEC97DCF
       8EC9B55A 7F88A46B 4DB5A851 F44182E1 C68A007E 5E0DD902
       0BFD64B6 45036C7A 4E677D2C 38532A3A 23BA4442 CAF53EA6
       3BB45432 9B7624C8 917BDD64 B1C0FD4C B38E8C33 4C701C3A
       CDAD0657 FCCFEC71 9B1F5C3E 4E46041F 388147FB 4CFDB477
       A52471F7 A9A96910 B855322E DB6340D8 A00EF092 350511E3
       0ABEC1FF F9E3A26E 7FB29F8C 183023C3 587E38DA 0077D9B4
       763E4E4B 94B2BBC1 94C6651E 77CAF992 EEAAC023 2A281BF6
       B3A739C1 22611682 0AE8DB58 47A67CBE F9C9091B 462D538C
       D72B0374 6AE77F5E 62292C31 1562A846 505DC82D B854338A
       E49F5235 C95B9117 8CCF2DD5 CACEF403 EC9D1810 C6272B04
       5B3B71F9 DC6B80D6 3FDD4A8E 9ADB1E69 62A69526 D43161C1
       A41D570D 7938DAD4 A40E329C D0E40E65 FFFFFFFF FFFFFFFF"

  let ffdhe8192 =
    (* p = 2^8192 - 2^8128 + {[2^8062 * e] + 10965728} * 2^64 - 1 *)
    (* The estimated symmetric-equivalent strength of this group is 192 bits.

       Peers using ffdhe8192 that want to optimize their key exchange with a
       short exponent (Section 5.2) should choose a secret key of at least
       400 bits. *)
    s_group ~p:
      "FFFFFFFF FFFFFFFF ADF85458 A2BB4A9A AFDC5620 273D3CF1
       D8B9C583 CE2D3695 A9E13641 146433FB CC939DCE 249B3EF9
       7D2FE363 630C75D8 F681B202 AEC4617A D3DF1ED5 D5FD6561
       2433F51F 5F066ED0 85636555 3DED1AF3 B557135E 7F57C935
       984F0C70 E0E68B77 E2A689DA F3EFE872 1DF158A1 36ADE735
       30ACCA4F 483A797A BC0AB182 B324FB61 D108A94B B2C8E3FB
       B96ADAB7 60D7F468 1D4F42A3 DE394DF4 AE56EDE7 6372BB19
       0B07A7C8 EE0A6D70 9E02FCE1 CDF7E2EC C03404CD 28342F61
       9172FE9C E98583FF 8E4F1232 EEF28183 C3FE3B1B 4C6FAD73
       3BB5FCBC 2EC22005 C58EF183 7D1683B2 C6F34A26 C1B2EFFA
       886B4238 611FCFDC DE355B3B 6519035B BC34F4DE F99C0238
       61B46FC9 D6E6C907 7AD91D26 91F7F7EE 598CB0FA C186D91C
       AEFE1309 85139270 B4130C93 BC437944 F4FD4452 E2D74DD3
       64F2E21E 71F54BFF 5CAE82AB 9C9DF69E E86D2BC5 22363A0D
       ABC52197 9B0DEADA 1DBF9A42 D5C4484E 0ABCD06B FA53DDEF
       3C1B20EE 3FD59D7C 25E41D2B 669E1EF1 6E6F52C3 164DF4FB
       7930E9E4 E58857B6 AC7D5F42 D69F6D18 7763CF1D 55034004
       87F55BA5 7E31CC7A 7135C886 EFB4318A ED6A1E01 2D9E6832
       A907600A 918130C4 6DC778F9 71AD0038 092999A3 33CB8B7A
       1A1DB93D 7140003C 2A4ECEA9 F98D0ACC 0A8291CD CEC97DCF
       8EC9B55A 7F88A46B 4DB5A851 F44182E1 C68A007E 5E0DD902
       0BFD64B6 45036C7A 4E677D2C 38532A3A 23BA4442 CAF53EA6
       3BB45432 9B7624C8 917BDD64 B1C0FD4C B38E8C33 4C701C3A
       CDAD0657 FCCFEC71 9B1F5C3E 4E46041F 388147FB 4CFDB477
       A52471F7 A9A96910 B855322E DB6340D8 A00EF092 350511E3
       0ABEC1FF F9E3A26E 7FB29F8C 183023C3 587E38DA 0077D9B4
       763E4E4B 94B2BBC1 94C6651E 77CAF992 EEAAC023 2A281BF6
       B3A739C1 22611682 0AE8DB58 47A67CBE F9C9091B 462D538C
       D72B0374 6AE77F5E 62292C31 1562A846 505DC82D B854338A
       E49F5235 C95B9117 8CCF2DD5 CACEF403 EC9D1810 C6272B04
       5B3B71F9 DC6B80D6 3FDD4A8E 9ADB1E69 62A69526 D43161C1
       A41D570D 7938DAD4 A40E329C CFF46AAA 36AD004C F600C838
       1E425A31 D951AE64 FDB23FCE C9509D43 687FEB69 EDD1CC5E
       0B8CC3BD F64B10EF 86B63142 A3AB8829 555B2F74 7C932665
       CB2C0F1C C01BD702 29388839 D2AF05E4 54504AC7 8B758282
       2846C0BA 35C35F5C 59160CC0 46FD8251 541FC68C 9C86B022
       BB709987 6A460E74 51A8A931 09703FEE 1C217E6C 3826E52C
       51AA691E 0E423CFC 99E9E316 50C1217B 624816CD AD9A95F9
       D5B80194 88D9C0A0 A1FE3075 A577E231 83F81D4A 3F2FA457
       1EFC8CE0 BA8A4FE8 B6855DFE 72B0A66E DED2FBAB FBE58A30
       FAFABE1C 5D71A87E 2F741EF8 C1FE86FE A6BBFDE5 30677F0D
       97D11D49 F7A8443D 0822E506 A9F4614E 011E2A94 838FF88C
       D68C8BB7 C5C6424C FFFFFFFF FFFFFFFF"

end
