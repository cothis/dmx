/* x86 raises a fault on a division by zero and on a quotient too large for its register, and programs rely on
 * it: .NET and the JVM turn it into their exceptions. arm64's division does neither, so an emulator has to. Every
 * width of DIV and IDIV: the handler must run with SIGFPE and FPE_INTDIV, RIP on the instruction, and the destination
 * registers untouched. Divisions that fit must still give the right answer. Linux x86-64 ABI. */
.global _start
.text
_start:
    /* with arguments, each of which must end the program with SIGFPE: one, a division by zero with SIGFPE at its
       default. Two, the same with SIGFPE blocked. Three, a division by zero in a handler for SIGFPE.
       Four: install a handler, restore SIG_DFL, then divide by zero, for inherited SIG_IGN regression coverage. */
    mov (%rsp), %r12
    cmp $1, %r12
    je 3f
    cmp $3, %r12
    jne 1f
    mov $14, %eax
    xor %edi, %edi
    lea mask_fpe(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
1:  cmp $4, %r12
    jne 2f
    mov $13, %eax
    mov $8, %edi
    lea fatal_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
2:  cmp $5, %r12
    jne 4f
    mov $13, %eax
    mov $8, %edi
    lea fatal_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $13, %eax
    lea default_action(%rip), %rsi
    syscall
4:  xor %ecx, %ecx
    mov $1, %eax
    xor %edx, %edx
    idivl %ecx
    jmp fail
3:
    mov $13, %eax
    mov $8, %edi
    lea action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js fail

    /* zero divisors */
    xor %ecx, %ecx
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  divb %cl
    call check_fault
    mov $100, %eax
    lea 1f(%rip), %r15
1:  idivb %cl
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  divw %cx
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  idivw %cx
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  divl %ecx
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  idivl %ecx
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  divq %rcx
    call check_fault
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  idivq %rcx
    call check_fault
    /* a divisor in memory, and the many times a loop would */
    mov $100000, %r13d
loop:
    mov $100, %eax
    xor %edx, %edx
    lea 1f(%rip), %r15
1:  idivl zero(%rip)
    call check_fault
    dec %r13d
    jnz loop

    /* quotients that do not fit */
    mov $0x100, %eax
    mov $1, %ecx
    lea 1f(%rip), %r15
1:  divb %cl
    call check_fault
    mov $0x8000, %eax
    mov $-1, %ecx
    lea 1f(%rip), %r15
1:  idivb %cl
    call check_fault
    mov $1, %edx
    xor %eax, %eax
    mov $1, %ecx
    lea 1f(%rip), %r15
1:  divw %cx
    call check_fault
    mov $0x8000, %eax
    mov $0xffff, %edx
    mov $-1, %ecx
    lea 1f(%rip), %r15
1:  idivw %cx
    call check_fault
    mov $1, %edx
    xor %eax, %eax
    mov $1, %ecx
    lea 1f(%rip), %r15
1:  divl %ecx
    call check_fault
    mov $0x80000000, %eax
    mov $0xffffffff, %edx
    mov $-1, %ecx
    lea 1f(%rip), %r15
1:  idivl %ecx
    call check_fault
    mov $1, %edx
    xor %eax, %eax
    mov $1, %ecx
    lea 1f(%rip), %r15
1:  divq %rcx
    call check_fault
    movabs $0x8000000000000000, %rax
    mov $-1, %rdx
    mov $-1, %rcx
    lea 1f(%rip), %r15
1:  idivq %rcx
    call check_fault
    /* above the sign bit, for a quotient that fits in 64 bits only without it */
    movabs $0x8000000000000000, %rax
    xor %edx, %edx
    mov $1, %ecx
    lea 1f(%rip), %r15
1:  idivq %rcx
    call check_fault

    /* the flags of the fault are those from before the instruction: 1 - 2 sets CF, PF, AF and SF */
    mov $1, %eax
    xor %edx, %edx
    xor %ecx, %ecx
    cmp $2, %eax
    lea 1f(%rip), %r15
1:  divl %ecx
    xor %r8d, %r8d
    mov seen_eflags(%rip), %r8
    and $0x8d5, %r8d
    cmp $0x95, %r8d
    jne fail
    call check_fault

    /* so is x87 state, in the block with the division, and it comes back */
    mov $1, %eax
    xor %edx, %edx
    xor %ecx, %ecx
    fld1
    lea 1f(%rip), %r15
1:  divl %ecx
    fstpl x87_value(%rip)
    call check_fault
    movabs $0x3ff0000000000000, %r8
    cmp x87_value(%rip), %r8
    jne fail

    /* what fits */
    cmpq $100019, faults(%rip)
    jne fail
    movq $0, faults(%rip)
    mov $100, %eax
    mov $7, %ecx
    divb %cl
    cmp $0x020e, %ax
    jne fail
    mov $-100, %eax
    cwd
    mov $7, %ecx
    idivw %cx
    cmp $-14, %ax
    jne fail
    cmp $-2, %dx
    jne fail
    mov $-100, %eax
    cltd
    mov $7, %ecx
    idivl %ecx
    cmp $-14, %eax
    jne fail
    cmp $-2, %edx
    jne fail
    /* the largest quotient that fits: 2^127 / 2^63 would not, this does */
    mov $0x7fffffff, %edx
    mov $0xffffffff, %eax
    shl $32, %rdx
    or %rax, %rdx
    mov $-1, %rax
    mov %rdx, %rbx
    mov %rbx, %rcx
    inc %rcx
    /* (2^63 - 1) : (2^64 - 1) / 2^63 = 2^64 - 1, remainder 2^63 - 1 */
    divq %rcx
    cmp $-1, %rax
    jne fail
    cmp %rbx, %rdx
    jne fail
    /* -1 : -1 by -1 is 1 */
    mov $-1, %rax
    mov $-1, %rdx
    mov $-1, %rcx
    idivq %rcx
    cmp $1, %rax
    jne fail
    test %rdx, %rdx
    jne fail
    /* INT64_MIN by 1 */
    movabs $0x8000000000000000, %rax
    mov $-1, %rdx
    mov $1, %ecx
    idivq %rcx
    movabs $0x8000000000000000, %rcx
    cmp %rcx, %rax
    jne fail
    /* a dividend that takes 128 bits: 2^63 by -1 is the 64-bit minimum */
    movabs $0x8000000000000000, %rax
    xor %edx, %edx
    mov $-1, %rcx
    idivq %rcx
    movabs $0x8000000000000000, %rcx
    cmp %rcx, %rax
    jne fail
    test %rdx, %rdx
    jne fail
    /* -(2^64) by 2^4 */
    xor %eax, %eax
    mov $-1, %rdx
    mov $16, %ecx
    idivq %rcx
    movabs $0xf000000000000000, %rcx
    cmp %rcx, %rax
    jne fail
    test %rdx, %rdx
    jne fail
    cmpq $0, faults(%rip)
    jne fail

    mov $1, %eax
    mov $1, %edi
    lea good(%rip), %rsi
    mov $good_end-good, %edx
    syscall
    mov $231, %eax
    xor %edi, %edi
    syscall

/* The handler recorded the destination registers it found and the instruction's address. */
check_fault:
    cmpq $1, seen(%rip)
    jne fail
    movq $0, seen(%rip)
    incq faults(%rip)
    cmp seen_rip(%rip), %r15
    jne fail
    cmpq $8, seen_signo(%rip)
    jne fail
    cmpq $1, seen_code(%rip)
    jne fail
    cmp seen_rax(%rip), %rax
    jne fail
    cmp seen_rdx(%rip), %rdx
    jne fail
    ret

/* siginfo: si_signo at 0, si_code at 8. uc_mcontext gregs at 40: RDX 13th, RAX 14th, RIP 17th, EFLAGS 18th. The handler moves
 * RIP past the instruction, which it finds by its opcode: F6 or F7, a prefix or two before it, and a ModRM. */
fatal_handler:
    xor %ecx, %ecx
    mov $1, %eax
    xor %edx, %edx
    idivl %ecx
    ret
handler:
    incq seen(%rip)
    mov 176(%rdx), %rax
    mov %rax, seen_eflags(%rip)
    movslq (%rsi), %rax
    mov %rax, seen_signo(%rip)
    movslq 8(%rsi), %rax
    mov %rax, seen_code(%rip)
    mov 168(%rdx), %rax
    mov %rax, seen_rip(%rip)
    mov 136(%rdx), %rcx
    mov %rcx, seen_rdx(%rip)
    mov 144(%rdx), %rcx
    mov %rcx, seen_rax(%rip)
1:  movzbl (%rax), %ecx
    inc %rax
    cmp $0xf6, %ecx
    je 2f
    cmp $0xf7, %ecx
    jne 1b
2:  movzbl (%rax), %ecx
    inc %rax
    /* ModRM 00 101 r/m with r/m 101 is RIP-relative, four bytes more */
    and $0xc7, %ecx
    cmp $0x05, %ecx
    jne 3f
    add $4, %rax
3:  mov %rax, 168(%rdx)
    ret
restorer:
    mov $15, %eax
    syscall
fail:
    mov $1, %eax
    mov $1, %edi
    lea bad(%rip), %rsi
    mov $bad_end-bad, %edx
    syscall
    mov $231, %eax
    mov $1, %edi
    syscall

.data
.align 8
action:
    .quad handler, 0x04000004, restorer, 0
fatal_action:
    .quad fatal_handler, 0x04000004, restorer, 0
mask_fpe:
    .quad 1 << 7
seen_eflags:
    .quad 0
x87_value:
    .quad 0
default_action:
    .quad 0, 0, 0, 0
zero:
    .quad 0
seen:
    .quad 0
faults:
    .quad 0
seen_signo:
    .quad 0
seen_code:
    .quad 0
seen_rip:
    .quad 0
seen_rax:
    .quad 0
seen_rdx:
    .quad 0
good:
    .ascii "div-fault-ok\n"
good_end:
bad:
    .ascii "div-fault-FAILED\n"
bad_end:
