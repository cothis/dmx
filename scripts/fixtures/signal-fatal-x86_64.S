/* Ways to end a program with SIGSEGV, each of which must end it, by the number of arguments:
 * none: a handler resets to the default and raises the signal again, as a crash reporter does, and returns.
 * one: a handler faults, with its own signal blocked.
 * two: a fault with SIGSEGV ignored. Three: a fault without installing a handler. Linux x86-64 ABI. */
.global _start
.text
_start:
    mov (%rsp), %r12
    mov $39, %eax
    syscall
    mov %rax, pid(%rip)
    mov $186, %eax
    syscall
    mov %rax, tid(%rip)
    cmp $4, %r12
    je fault
    cmp $3, %r12
    je ignored
    lea reraise_action(%rip), %rsi
    cmp $2, %r12
    jne 1f
    lea fault_action(%rip), %rsi
1:  mov $13, %eax
    mov $11, %edi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js survived
    cmp $2, %r12
    je fault
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $11, %edx
    syscall
    /* the way back from the handler, and a little further: it ends here at the latest */
    mov $1000, %ecx
2:  dec %ecx
    jnz 2b
    jmp survived
ignored:
    mov $13, %eax
    mov $11, %edi
    lea ignore_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    test %rax, %rax
    js survived
fault:
    xor %eax, %eax
    mov (%rax), %rbx
survived:
    mov $1, %eax
    mov $1, %edi
    lea alive(%rip), %rsi
    mov $alive_end-alive, %edx
    syscall
    mov $231, %eax
    mov $1, %edi
    syscall

reraise_handler:
    mov $13, %eax
    mov $11, %edi
    lea default_action(%rip), %rsi
    xor %edx, %edx
    mov $8, %r10d
    syscall
    mov $234, %eax
    mov pid(%rip), %rdi
    mov tid(%rip), %rsi
    mov $11, %edx
    syscall
    ret
fault_handler:
    xor %eax, %eax
    mov (%rax), %rbx
    ret
restorer:
    mov $15, %eax
    syscall

.data
.align 8
reraise_action:
    .quad reraise_handler, 0x04000004, restorer, 0
fault_action:
    .quad fault_handler, 0x04000004, restorer, 0
default_action:
    .quad 0, 0x04000000, restorer, 0
ignore_action:
    .quad 1, 0x04000000, restorer, 0
pid:
    .quad 0
tid:
    .quad 0
alive:
    .ascii "signal-fatal-SURVIVED\n"
alive_end:
