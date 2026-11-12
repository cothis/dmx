---- MODULE Properties ----
VARIABLES foreignHV, freedRAM, done
NoForeignHV == ~foreignHV
NoFreedRAM == ~freedRAM
NeverCompletes == ~done
====
