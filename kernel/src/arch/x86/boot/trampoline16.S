/* SPDX-License-Identifier: MIT */

/* StACSOS Kernel - Core
 *
 * Copyright (C) University of St Andrews 2024.  All Rights Reserved.
 * Tom Spink <tcs6@st-andrews.ac.uk>
 */

/* AP per-core scratch stacks live immediately after the BSP's scratch region
 * from start32.S (SCRATCH_MEMORY = 0x100000, consuming 5 pages: one boot stack
 * page + PML4 + PDP_LO/MID/HI), which ends at 0x105000.  One 4K page per core. */
#define TRAMPOLINE_SCRATCH_MEMORY  0x105000

/* These must match the definitions in start32.S — the BSP sets up the page
 * tables at SCRATCH_MEMORY and the control-register bits are architectural. */
#define SCRATCH_MEMORY  0x100000
#define PML4            (SCRATCH_MEMORY + 0x1000)

/* CR0 */
#define CR0_PE  (1u << 0)
#define CR0_MP  (1u << 1)
#define CR0_NE  (1u << 5)
#define CR0_WP  (1u << 16)
#define CR0_PG  (1u << 31)

/* CR4 */
#define CR4_PSE        (1u << 4)
#define CR4_PAE        (1u << 5)
#define CR4_PGE        (1u << 7)
#define CR4_OSFXSR     (1u << 9)
#define CR4_OSXMMEXCPT (1u << 10)
#define CR4_FSGSBASE   (1u << 16)

/* EFER */
#define EFER_SCE    (1u << 0)
#define EFER_LME    (1u << 8)
#define EFER_NXE    (1u << 11)

.code16
.section .trampoline.text16, "ax"

.align 16

/* Entry point — bring this AP from 16-bit real mode to 64-bit long mode */
trampoline_start:
    cli                          # Disable interrupts
    cld                          # Reset directions of string instructions
    jmp    trampoline16_main
    .align 16

/* ── Real-mode (PM16) GDT ───────────────────────────────────────────────── */
gdt_real:
    .long 0, 0
    .long 0x0000FFFF, 0x00CF9A00    /* flat code */
    .long 0x0000FFFF, 0x008F9200    /* flat data */
    .align 16

gdtr_real:
    .word gdtr_real - gdt_real - 1
gdtr_real_base:
    .long 0                          /* base — patched at runtime */
    .long 0, 0
    .align 16

farjmp_real:
    .long 0                          /* 32-bit offset — patched at runtime */
    .word 0x08                       /* selector — flat PM code */
    .align 16

/* ── 16-bit trampoline code ─────────────────────────────────────────────── */
trampoline16_main:
    movw    %cs, %ax                # Copy the CS segment over to DS
    movw    %ax, %ds

    /* The segment base (CS * 16) is the linear address this trampoline was
       loaded at.  Both the GDTR base and the far-jump offset are linear
       addresses, so compute the base once and keep it in EDX. */
    xorl    %edx, %edx
    movw    %cs, %dx
    shll    $4, %edx           # EDX = CS * 16 = linear base of the trampoline

    /* Patch the GDT descriptor's base field with the linear address of gdt_real.
       Must happen BEFORE lgdtl, which reads the descriptor. */
    leal    (gdt_real - trampoline_start)(%edx), %eax   # base + gdt_real offset
    movl    %eax, (gdtr_real_base - trampoline_start)   # GDTR base field

    lgdtl   (gdtr_real - trampoline_start)              # load the GDT (now with a correct linear base)

    movl    %cr0, %eax         # get cr0
    orl     $1, %eax           # set bit 0 (PE)
    movl    %eax, %cr0         # set cr0, protection enabled

    /* Patch the far-jump offset with the linear address of trampoline32_main. */
    leal    (trampoline32_main - trampoline_start)(%edx), %eax   # base + trampoline32_main offset
    movl    %eax, (farjmp_real - trampoline_start)               # far-jump offset field

    ljmpl   *(farjmp_real - trampoline_start)                    # far jump to trampoline32_main (PM32)
    .align 16

/* ── Null IDTR ──────────────────────────────────────────────────────────── */
null_idtr:
    .word 0
    .long 0
    .align 4

/* ── Long-mode GDT ──────────────────────────────────────────────────────── */
gdt_long:
    .quad 0x0000000000000000         /* NULL */
    .quad 0x00209A0000000000         /* 64-bit code @ 0x08 */
    .quad 0x0000920000000000         /* data       @ 0x10 */
gdt_long_end:
    .align 4

gdtr_long:
    .word (gdt_long_end - gdt_long - 1)
gdtr_long_base:
    .long 0                          /* base — patched at runtime */
    .align 16

    .code32
/* ── 32-bit far-jump descriptor (protected → long mode) ─────────────────── */
farjmp_long:
    .long 0                          /* 32-bit offset — patched at runtime */
    .word 0x08                       /* selector — 64-bit code */
    .align 16

/* ── 32-bit trampoline code ─────────────────────────────────────────────── */
trampoline32_main:
    # Zero out segment selectors
    movw   $0x10, %ax          # flat data selector
    movw   %ax, %ds            # (ds/es/ss still hold stale real-mode values here)
    movw   %ax, %es
    movw   %ax, %ss

    # Get this CPUs scratch stack section
    movl $1, %eax                    # increment amount for the atomic add
    lock xaddl %eax, (trampoline_data_asm_count - trampoline_start)(%edx) # eax = old counter = this core's index; counter++
    movl %eax, %ebp                  # keep the raw core index in ebp for later use
    shll $12, %eax                   # index * 4096 = this core's page offset
    addl $TRAMPOLINE_SCRATCH_MEMORY, %eax # Determine where the trampolines stack should fit in
    addl $0x1000, %eax                    # The top of that page is the top of the stack
    movl %eax, %esp                      # Now each core has there own stack
    movl %eax, %esi                      # Save this address for later access

    mov $PML4, %eax
    mov %eax, %cr3

    pushl %edx                               # save trampoline base — CPUID and WRMSR both clobber EDX

    # Check for FSGSBASE
    mov $7, %eax
    xor %ecx, %ecx
    cpuid
    bt $0, %ebx

    mov $(CR4_PSE | CR4_PAE | CR4_PGE | CR4_OSFXSR | CR4_OSXMMEXCPT | CR4_FSGSBASE), %eax
    jc has_fsgs
    and $(~CR4_FSGSBASE), %eax
has_fsgs:
    # Initialise CR4
    mov %eax, %cr4

    # Initialise EFER
    mov $(0xC0000080), %ecx
    xor %edx, %edx
    mov $(EFER_SCE | EFER_LME | EFER_NXE), %eax
    wrmsr

    popl %edx                                # restore trampoline base

    # Initialise CR0
    mov $(CR0_PG | CR0_PE | CR0_MP | CR0_WP | CR0_NE), %eax
    mov %eax, %cr0

    /* Patch gdtr_long base with the linear address of gdt_long */
    leal    (gdt_long - trampoline_start)(%edx), %eax
    movl    %eax, (gdtr_long_base - trampoline_start)(%edx)

    # Load a null IDT
    lidt    (null_idtr  - trampoline_start)(%edx)

    # Load the temporary GDT
    lgdt    (gdtr_long  - trampoline_start)(%edx)

    # PATCH FARJUMP to trampoline64_start
    leal    (trampoline64_start - trampoline_start)(%edx), %eax
    movl    %eax, (farjmp_long - trampoline_start)(%edx)

    # Compute the linear address of the closure pointer here, while we are still
    # in the .trampoline.text16 section. Calculation must be in the same section
    leal    (trampoline_data_asm_ptr - trampoline_start)(%edx), %edi

    ljmp    *(farjmp_long - trampoline_start)(%edx)     # jump to trampoline64_start (long mode)

    .align 16
    .code64
    .section .trampoline.text64, "ax"
trampoline64_start:
    # OK - we're nearly there now!  We've made it to 64-bit mode, so get the
    # final things ready before we go into our main C++ code.

    # Re-initialise segment registers
    mov $0x10, %eax
    mov %ax, %ds
    mov %ax, %es
    mov %ax, %ss

    xor %eax, %eax
    mov %ax, %fs
    mov %ax, %gs

    # Reset your cores stack pointer
    movl %esi, %esp

    # Then adjust so that it is accessed through the memory mapped full window
    mov $0xffff800000000000, %rcx
    add %rcx, %rsp

    # rdi holds the pointer given to use by the kernel
    # We need to zero upper 32 bits of rdi
    mov %edi, %edi
    jmp *(%rdi)

.section .trampoline.data, "aw"

/*
    Stores the closure pointer, the same for all started up APs
 */
.align 8
.globl trampoline_data_asm
.type trampoline_data_asm, %object
trampoline_data_asm:
trampoline_data_asm_count:
    .long 0
trampoline_data_asm_ptr:
    .quad 0     /* void (*trampoline)()    (offset 4) */
.size trampoline_data_asm,.-trampoline_data_asm
