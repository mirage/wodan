open Lwt.Infix
open V1_LWT

module Client (C: CONSOLE) (B: BLOCK) = struct

  let start con disk =
    Lwt.return ()
end
