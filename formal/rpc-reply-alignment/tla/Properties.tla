---------------------------- MODULE Properties ----------------------------
EXTENDS Naturals
VARIABLES delivered, sent, badReuse
NoMismatchedReply == \A c \in 1..2 : delivered[c] = 0 \/ delivered[c] = c
NoReplay == \A c \in 1..2 : sent[c] <= 1
NoUncertainReuse == ~badReuse
=============================================================================
