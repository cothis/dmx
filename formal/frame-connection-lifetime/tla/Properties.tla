--------------------------- MODULE Properties ---------------------------
\* Frozen protocol requirements. Do not weaken to make the implementation pass.
VARIABLES foreignIO, lateAcquire

NoForeignIO == ~foreignIO
NoLateAcquire == ~lateAcquire
=============================================================================
