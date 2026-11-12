---- MODULE Properties ----
VARIABLES rejected, sent
NoLegalInputRejected == ~rejected
NeverSends == sent = 0
====
