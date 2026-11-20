// Stops the dmx VM as failed from inside the guest: maps an unclaimed MMIO page through /dev/mem
// and reads it with `ldp`, a load whose data abort carries no instruction syndrome, which dmx's
// VMM cannot emulate (VCPU: "data abort without a valid syndrome"). Exits 1 if it cannot try.
.global _start
.text
_start:
    mov x0, #-100           // openat(AT_FDCWD, "/dev/mem", O_RDWR)
    adr x1, path
    mov x2, #2
    mov x3, #0
    mov x8, #56
    svc #0
    cmp x0, #0
    b.lt fail
    mov x4, x0              // mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_SHARED, fd, 0x0a100000)
    mov x0, #0
    mov x1, #4096
    mov x2, #3
    mov x3, #1
    movz x5, #0x0a10, lsl #16
    mov x8, #222
    svc #0
    cmn x0, #4095
    b.hi fail
    ldp x1, x2, [x0]        // the VM stops here
    mov x0, #0
    mov x8, #93
    svc #0
fail:
    mov x0, #1
    mov x8, #93
    svc #0
path:
    .asciz "/dev/mem"
