/* SPDX-License-Identifier: MIT */

/* StACSOS Kernel - Core
 *
 * Copyright (C) University of St Andrews 2024.  All Rights Reserved.
 * Tom Spink <tcs6@st-andrews.ac.uk>
 */
.code16
.section .trampoline.text16, "ax"

.align 16

.type trampoline16, %function
trampoline16:   
    /*We need to get this fresh core from 16 bit real to 64 bit long*/
    movw $0x6767, %ax
    movw %ax, 0x8100
    hlt
.align 16

/* TODO: Make independant of page run in ideally*/

.section .trampoline.data, "aw"

/* 
    Stores the closure pointer, the same for all started up APs
 */
.align 8
.globl trampoline_data_asm
.type trampoline_data_asm, %object
trampoline_data_asm:
    .quad 0     /* void (*trampoline)()    (offset 0) */
.size trampoline_data_asm,.-trampoline_data_asm