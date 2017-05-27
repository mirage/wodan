open Ocamlbuild_plugin;;

rule "qtest extract"
        ~prod:"%_tests.ml"
        ~deps:["%.ml"]
        (fun env build ->
                Cmd(S[A"qtest"; A"extract"; A"-o"; P(env "%_tests.ml"); P(env "%.ml")]))

