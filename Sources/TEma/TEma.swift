//
//  TEma.swift
//  TEma, a stack-based computer.
//
//  Created by teo on 24/07/2021.
//

import Foundation
import AppKit

public class TEma {
    
    enum SystemError: Error {
    case memoryLoading
    }
    static public let displayHResolution = 640
    static public let displayVResolution = 480
    
    public var cpu: CPU
    public var mmu: MMU
    
    public var bus: [Bus?]
   
    public init() {
        cpu = CPU()
        mmu = MMU()

        /// The bus ids are as follows:
        /// 0 - system
        /// 1 - console
        /// 2 - display
        /// 3 - audio
        /// 4 - controller 1
        /// 5 - controller 2
        /// 6 - mouse
        
        bus = [Bus?](repeating: nil, count: 16)
        cpu.sys = self
    }
    
    public func registerBus(id: Bus.Device, name: String, comms: @escaping (Bus, UInt8, UInt8)->Void) -> Bus {
        print("Registered bus: \(id) \(name) at \(id.rawValue << 4)")
        let newbus = Bus(id: id, owner: self, comms: comms)
        bus[Int(id.rawValue)] = newbus
        return newbus
    }
    
    public func loadRam(destAddr: UInt16, ram: [UInt8]) throws {
        guard ram.count+Int(destAddr) <= MMU.byteSize else { throw SystemError.memoryLoading }
        
        for idx in ram.indices {
            mmu.write(value: ram[idx], address: destAddr+UInt16(idx))
        }
    }
    
    public func tests() {

    }
}

/// Bus between devices
public class Bus {
    let address: UInt8  // a bus is referenced via a particular address in TEma RAM: Device id * 0x10
    let owner: TEma
    let comms: ((Bus, UInt8, UInt8)->(Void))
    // The position in the buffer represents a particular "port" for the device we're communicating with
    // eg. on a console bus 0x2 is the read port and 0x8 is write port.
    public var buffer = [UInt8](repeating: 0, count: 16)
    
    public enum Device: UInt8 {
        case system
        case console
        case display
        case audio
        case controller1 = 0x8
        case mouse
        case file = 0xA0
    }
    
    init(id: Device, owner: TEma, comms: @escaping (Bus, UInt8, UInt8)->(Void)) {
        self.address = id.rawValue * 0x10
        self.owner = owner
        self.comms = comms
    }
    
    
    public func busRead(a: UInt8) -> UInt8 {
        comms(self, a & 0x0F, 0)
        return buffer[Int(a & 0xF)]
    }
    
    public func busRead16(a: UInt8) -> UInt16 {
        return UInt16(busRead(a: a)) << 8 | UInt16(busRead(a: a + 1))
    }
    
    public func busWrite(a: UInt8, b: UInt8) {
        buffer[Int(a & 0xF)] = b
        comms(self, a & 0x0F, 1)
        // MARK: confirm that the 0 is not needed in the 0x0F
    }
    
    public func busWrite16(a: UInt8, b: UInt16) {
        busWrite(a:a, b: UInt8(b >> 8))
        busWrite(a:a+1, b: UInt8(b & 0xFF))
    }
}

class Stack {
        
    enum StackError: Error {
        case underflow
        case overflow
    }
    
    static let stBytes = 256
    private var data = [UInt8](repeating: 0, count: stBytes)
    var count = 0
    var copyIdx = 0
/*
    var copyIdxBak: Int?  // backup of copyIdx when interrupt handler runs
    private var _irqMode: Bool = false
    var irqMode: Bool {
        set {
            _irqMode = newValue
            if _irqMode == true { copyIdxBak = copyIdx ; copyIdx = count }
            else { copyIdx = copyIdxBak! ; copyIdxBak = nil }
        }
        get { _irqMode }
    }
    */
    
    func push8(_ val: UInt8) throws {
        guard count < Stack.stBytes else { throw StackError.overflow }
        data[count] = val
        count += 1
        copyIdx = count
    }
    
    func push16(_ val: UInt16) throws {
        guard count < Stack.stBytes-1 else { throw StackError.overflow }
        try push8(UInt8(val >> 8)) ; try push8(UInt8(val & 0xFF))
    }
    
    func pop8() throws -> UInt8 {
        guard count > 0 else { throw StackError.underflow }
        count -= 1
        copyIdx = count
        return data[count]
    }
    
    func popCopy8() throws -> UInt8 {
        guard copyIdx > 0 else { throw StackError.underflow }
        copyIdx -= 1
        return data[copyIdx]
    }

    func pop16() throws -> UInt16 {
        let a = try pop8() ; let b = try pop8()
        return (UInt16(b) << 8) | UInt16(a & 0xFF)
    }
    
    func popCopy16() throws -> UInt16 {
        let a = try popCopy8() ; let b = try popCopy8()
        return (UInt16(b) << 8) | UInt16(a)
    }
    
    func debugPrint() {
        print("[ ", terminator: "")
        for idx in 0..<count { print("0x\(String(format:"%02X", data[idx])) ", terminator: "") }
        print("]")
    }
}

/// Central Processing Unit
public class CPU {
        
    /// A possible alternative is to define each operation as a method and then
    /// have an array of methods whose position matches their opcode.
    /// The clock tick method would then just read an opcode from memory and use it as an index into the operation array.
    /// With the retrieved method you can then just call it
    /// (using op(CPU)() because methods are curried. see http://web.archive.org/web/20201225064902/https://oleb.net/blog/2014/07/swift-instance-methods-curried-functions/)
    
    static let boolVal: UInt8 = 0x01
    
    // NOTE: Any changes in the number or order of the opcodes needs to be reflected in the TEas assembler.
    // Also, exactly duplicate short opcodes so each is a fixed (0x20) offset from its byte counterpart.
    // Eg. lit16 (0x22) is exactly 0x20 from lit (0x02) and so are all the other short ops.
    enum OpCode: UInt8 {
        case brk
        case nop
        
        // stack operations
        case lit
        case pop
        case dup
        case ovr
        case rot
        case swp
        case sts    // stack to stack transfer
        
        // arithmetical operations
        case add
        case sub
        case mul
        case div
        
        // bitwise logic
        case and
        case ior
        case xor
        case shi

        // logic operations
        case equ
        case neq
        case grt
        case lst
        /// there is always  a trade-off between space and time; we can have a single equality and a single greater than operator and
        /// achieve its complements by having a negation operation, but this comes at the cost of run-time complexity where each of
        /// these tests would require two ops and two cycles instead of one. After consideration i have decided, since there is room for it,
        /// to have two more operations.
//        case neg    // negate the top of the stack
        case jmp    // jump unconditinally
        case jnz    // jump on true condition
        case jsr    // jump to subroutine
        
        // memory operations (the stack can be parameter or return stack depending on the return flag of the opcode)
        case lda    // load byte value from absoute address to stack
        case sta    // store byte value on top of stack at absolute address
        case ldr    // load byte value from relative address to stack
        case str    // store byte value from top of stack at relative address
        case bsi    // bus in
        case bso    // bus out
        
        // 16 bit operations (begin at 0x20)
        case lit16 = 0x22
        case pop16
        case dup16
        case ovr16
        case rot16
        case swp16
        case sts16
        
        // arithmetical operations
        case add16
        case sub16
        case mul16
        case div16
        
        // bitwise logic
        case and16
        case ior16
        case xor16
        case shi16

        // logic operations
        case equ16
        case neq16
        case grt16
        case lst16
//        case neg16  // negate the top of the stack

        case jmp16 //= 0x2F
        case jnz16    // jump on true condition
        case jsr16    // jump to subroutine
        
        // memory operations
        case lda16      // load short value from absoute address
        case sta16      // store short value at absolute address
        case ldr16      // load short value from relative address
        case str16      // store short value at relative address
        case bsi16    // bus in
        case bso16  // bus out
    }
    
    enum CPUError: Error {
    case missingParameters
        case pcBrk
        case invalidInterrrupt
    }
    
    /// Parameter stack, 256 bytes, unsigned
    var pStack = Stack()
    
    /// Return stack  256 bytes, unsigned
    var rStack = Stack()
    
    public var pc: UInt16 = 0
    
    /// Interconnects
    var sys: TEma!
        
    
    func reset() {
        pc = 0
        pStack.count = 0
        rStack.count = 0
        pStack.copyIdx = 0
        rStack.copyIdx = 0
    }
    
    public func run(ticks: Int) {
        var tc = ticks
        while tc > 0 {
            try? clockTick()
            tc -= 1
        }
    }
    
    // the interrupt master enable is in ram so that the interrupt function can access it without needing a special opcode (like RETI on GBA)
    let interruptMasterEnable: UInt16  = 0x00B0       // just after the bus addresses - by convention, so subject to change
    var interruptFlags: UInt8 = 0
    
    // caller must ensure these are not called concurrently. Perhaps not use interrupts next time?
    // Uses irQ for syncronization.
    public func interruptEnable(bus: Bus) {
        let IME = sys.mmu.read(address: interruptMasterEnable)
        guard IME == 1 else { return }
        // signal that an interrupt is now in progress. Must be reset by the interrupt function.
        sys.mmu.write(value: 0, address: interruptMasterEnable)
        
        // set the appropriate flag for the given bus. Only one for now.
        interruptFlags = bus.address >> 4
    }
    
    var dbgTickCount = 0
    
    func debugDump() {
        print("PC: 0x\(String(format:"%02X", pc))")
        print("pStack:", terminator: "")
        pStack.debugPrint()
        print("rStack:", terminator: "")
        rStack.debugPrint()
    }
    
    func clockTick() throws {
        
        // service interrupt requests
        if interruptFlags != 0 {
            let IME = sys.mmu.read(address: interruptMasterEnable)
            guard IME == 0 else { return }
                        
            guard let bus = sys.bus[Int(interruptFlags & 0xFF)] else { throw CPUError.invalidInterrrupt }
            interruptFlags = 0
            
            try rStack.push16(pc)
            let intvec = read16(mem: &bus.buffer, address: 0)
            pc = intvec
        }
                
        guard pc > 0 else { throw CPUError.pcBrk }
                
        /// since we're limiting the number of opcodes to 32 we are only using the bottom 5 bits.
        /// We can use the top three as flags for byte or short ops, copy rather than pop, and return from jump.
        /// This is where we would mask out the bottom 5 with an & 0x1F or, if we've made opcodes
        /// for both byte and shorts, the bottom 6 with ^ 0x3F
        let memval = sys.mmu.read(address: pc)

        // When the copy flag is set a pop operation will keep a copy of the byte or short that is popped.
        // Subsequent copy operations all return the last element (or two if the short flag is used as well) of the stack.
        let copyFlag = (memval & 0x40 != 0)
        let pop8: ((Stack) throws -> UInt8) = copyFlag ? { stack in stack.copyIdx = stack.count ; return try stack.popCopy8() } : { stack in try stack.pop8() }
        let pop16: ((Stack) throws -> UInt16) = copyFlag ? { stack in stack.copyIdx = stack.count ; return try stack.popCopy16() } : { stack in try stack.pop16() }
        
        let shortFlag = (memval & 0x20 != 0)
        let pop: ((Stack) throws -> UInt16) = shortFlag ? { stack in try pop16(stack) } : { stack in try UInt16(pop8(stack)) }
        let push: ((Stack, UInt16) throws -> Void) = shortFlag ? { stack, val in try stack.push16(val) } : { stack, val in try stack.push8(UInt8(val & 0xFF)) }
        /// The opcode byte layout:
        /// bytes 0, 1, 2, 3, 4 are opcode, 5 is byte or short flag, 6 is copy, 7 is stack swap
        /// If the stack swap flag is set, swap source and destination stacks
        let stackFlag = (memval & 0x80 != 0)
        let sourceStack: Stack = stackFlag ? rStack : pStack
        let targetStack: Stack = stackFlag ? pStack : rStack
        
        /// include the short flag in the opcode memory
        let op = OpCode(rawValue: memval & 0x3F) ; pc += 1
        dbgTickCount += 1
//        if dbgTickCount == 195 {
//            print("stop")
//        }
        
//        if pc == 0x02EF {
//            print("break1")
////            print("pStack count: \(pStack.count), copyidx: \(pStack.copyIdx) ")
//            debugDump()
//        }

        //print("clockTick \(dbgTickCount): read opcode: \(String(describing: op)) at pc \(pc)")
        if op == nil { fatalError("op is nil") }
        do {
        switch op {
        case .brk:
            debugDump()
            pc =  0
            
        case .nop:
            print("nop")
            
        /// stack operations
        case .lit:
            /// next value in memory assumed to be the value to push to pstack
            let lit = sys.mmu.read(address: pc)
            try sourceStack.push8(lit)
            pc += 1
            
        case .pop, .pop16:
            _ = try pop(sourceStack)
//            _ = try pop8(sourceStack)
//            let val = try pop8(sourceStack)
//            print("popped value \(String(describing: val))")

        case .dup, .dup16:
            let val = try pop(sourceStack)
            try push(sourceStack, val)
            try push(sourceStack, val)
            
        case .ovr, .ovr16: // ( b a -- b a b )
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b)
            try push(sourceStack, a)
            try push(sourceStack, b)
            
        case .rot, .rot16: // ( c b a -- b a c )
            
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)
            let c = try pop(sourceStack)

            try push(sourceStack, b)
            try push(sourceStack, a)
            try push(sourceStack, c)
            
        case .swp, .swp16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, a)
            try push(sourceStack, b)

        case .sts, .sts16:  // stack to stack transfer
            let a  = try pop(sourceStack)
            try push(targetStack, a)

        /// arithmetic operations
        case .add, .add16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b &+ a )
            
        case .sub, .sub16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b &- a )
            
        case .mul, .mul16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b &* a )

        case .div, .div16:

            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b / a )
            
        /// bitwise logic
        case .and, .and16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b & a )

        case .ior, .ior16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b | a )
            
        case .xor, .xor16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try push(sourceStack, b ^ a )
            
        case .shi: // ( value bitshift -- result )
            let a = try pop8(sourceStack)
            let b = try pop8(sourceStack)
            /// use the three least significant bits of the most significant nibble of a to shift up by 0 to 7 bits (the max needed for a byte) and
            /// use the three least significant bits of the least significant nibble of a to shift down by 0 to 7 bits.
            try sourceStack.push8((b >> (a & 0x07)) << ((a & 0x70) >> 4))
            
        /// logic operations
        case .equ, .equ16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try sourceStack.push8( b == a ? CPU.boolVal : 0 )

        case .neq, .neq16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try sourceStack.push8( b != a ? CPU.boolVal : 0 )

        case .grt, .grt16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try sourceStack.push8( b > a ? CPU.boolVal : 0 )
            

        case .lst, .lst16:
            let a = try pop(sourceStack)
            let b = try pop(sourceStack)

            try sourceStack.push8( b < a ? CPU.boolVal : 0 )
            
        case .jmp: /// unconditional relative jump
            let a = try pop8(sourceStack)

            /// relative jump is default
            pc = UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a)))
            
        case .jnz: /// conditional (not zero) relative jump
            let a = try pop8(sourceStack)   // address offset
            let b = try pop8(sourceStack)   // condition

            pc = b != 0 ?UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a))) : pc

        case .jsr:  /// jump to subroutine at offset, first storing the return address on the return stack
            let a = try pop8(sourceStack)
            
            /// store the current pc 16 bit address as 2 x 8 bits on the return stack, msb first
            try targetStack.push16(pc)//+1)
            
            pc = UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a)))
            
        // memory operations
// NOTE:           write 16 bit versions and use the sourcestack to allow use of the returnstack given the flag setting.
        case .lda:  // load the byte at the given absolute address onto the top of the parameter stack.
            let a = try pop16(sourceStack)
            try sourceStack.push8(sys.mmu.read(address: a))
            
        case .sta:  // ( value addr -- ) store the byte on top of the parameter stack to the given absolute address.
            let a = try pop16(sourceStack)
            let b = try pop8(sourceStack)
            sys.mmu.write(value: b, address: a)
            
        case .ldr:  // load the byte at the given relative address onto the top of the parameter stack.
            let a = try pop8(sourceStack)
            try sourceStack.push8(sys.mmu.read(address: UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a)))))
            
        case .str: // ( value addr -- ) store the byte on top of the parameter stack to the given relative address.
            let a = try pop8(sourceStack)
            let b = try pop8(sourceStack)
            sys.mmu.write(value: b, address: UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a))))
            
        case .bsi:
            let a = try pop8(sourceStack)
            if let bus = sys.bus[Int(a >> 4)] {
                try sourceStack.push8(bus.busRead(a: a))
            }
    
        case .bso: /// the  most significant nibble in a is the bus id and the lsn is the position in the bus.buffer (the port) that b is placed
            let a = try pop8(sourceStack)
            let b = try pop8(sourceStack)

            if let bus = sys.bus[Int(a >> 4)] {
                bus.busWrite(a: a, b: b)
            }
            
        // MARK: Implement short operations below.
        case .lit16:
            /// next value in memory assumed to be the value to push to pstack
            /// lit16 consists of an opcode byte followed by two bytes of data = 3 bytes total
            let lit = sys.mmu.read16(address: pc)
            pc += 2 // advance pc by the two bytes just read.
            try sourceStack.push16(lit)
            
        case .shi16: // ( value bitshift -- result )
            let a = try pop8(sourceStack)
            let b = try pop16(sourceStack)
            /// use the four least significant bits of the most significant nibble of a to shift up by 0 to f bits (the max needed for a short) and
            /// use the four least significant bits of the least significant nibble of a to shift down by 0 to f bits.
            try sourceStack.push16((b >> (a & 0x0f)) << ((a & 0xf0) >> 4))
        
        case .jmp16: /// unconditional absolute jump
            pc = try pop16(sourceStack)

        case .jnz16: /// conditional (not zero) absolute jump
            let a = try pop16(sourceStack)
            let b = try pop8(sourceStack)

            pc = (b == 0) ? pc : a
            
        case .jsr16:  /// jump to subroutine at absolute address, first storing the return address on the return stack
            let a = try pop16(sourceStack)
            
            /// store the current pc 16 bit address as 2 x 8 bits on the return stack, msb first
            try targetStack.push16(pc)
            pc = a
            
        // NOTE: Test these
        case .lda16:  // load the short at the given absolute address onto the top of the parameter stack.
            let a = try pop16(sourceStack)
            try sourceStack.push16(sys.mmu.read16(address: a))
            
        case .sta16:  // ( value addr -- ) store the short on top of the parameter stack to the given absolute address.
            let a = try pop16(sourceStack)
            let b = try pop16(sourceStack)
            sys.mmu.write16(value: b, address: a)
            
        case .ldr16:  // load the short at the given relative address onto the top of the parameter stack.
            let a = try pop8(sourceStack)
            try sourceStack.push16(sys.mmu.read16(address: UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a)))))
            
        case .str16: // ( value addr -- ) store the short on top of the parameter stack to the given relative address.
            let a = try pop8(sourceStack)
            let b = try pop16(sourceStack)
            sys.mmu.write16(value: b, address: UInt16(bitPattern: Int16(bitPattern: pc) + Int16(Int8(bitPattern: a))))

        case .bsi16: // NB: untested
            let a = try pop8(sourceStack)
            if let bus = sys.bus[Int(a >> 4)] {
                try sourceStack.push16(bus.busRead16(a: a))
            }

        case .bso16: /// the  most significant nibble in a is the bus id and the lsn is the position in the bus.buffer that b is placed
            let a = try pop8(sourceStack)
            let b = try pop16(sourceStack)
            
            if let bus = sys.bus[Int(a >> 4)] {
                bus.busWrite16(a: a, b: b)
            }
            
        default:
            print("unimplemented opcode: \(String(describing: op))")
        }
        } catch {
            print("ERROR: \(error)")
        }
    }
}

/// Memory Management Unit
public class MMU {
    static let byteSize = 65536
    let ramQ = DispatchQueue.global(qos: .userInitiated)
//    let ramQ = DispatchQueue(label: "thread-safe-obj", attributes: .concurrent)

    /// 65536 bytes of memory
   private var bank = [UInt8](repeating: 0, count: byteSize)
    
    func clear() {
        bank = [UInt8](repeating: 0, count: 65536)
    }
    
    public func write16(value: UInt16, address: UInt16) {
        write(value: UInt8(value >> 8), address: address)
        write(value: UInt8(value & 0xFF), address: address+1)
    }
    
    public func write(value: UInt8, address: UInt16) {
        // MARK: Occasional crash here when i don't use the ramQ.sync. Grok & fix!
//        ramQ.sync(flags: .barrier) {
            self.bank[Int(address)] = value
//        }
    }

    public func read16(address: UInt16) -> UInt16 {
//        return (UInt16(bank[Int(address)]) << 8) | UInt16(bank[Int(address+1)])
        return (UInt16(read(address: address)) << 8) | UInt16(read(address: address+1))
    }

    public func read(address: UInt16) -> UInt8 {
        // match ramQ use with write
//        ramQ.sync {
            return bank[Int(address)]
//        }
//        return bank[Int(address)]
    }
}

public func write16(mem: inout [UInt8], value: UInt16, address: UInt16) {
    write(mem: &mem, value: UInt8(value >> 8), address: address)
    write(mem: &mem, value: UInt8(value & 0xFF), address: address+1)
}

public func write(mem: inout [UInt8], value: UInt8, address: UInt16) {
    
    mem[Int(address)] = value
}

public func read16(mem: inout [UInt8], address: UInt16) -> UInt16 {
    return (UInt16(mem[Int(address)]) << 8) | UInt16(mem[Int(address+1)])
}

public func read(mem: inout [UInt8], address: UInt16) -> UInt8 {
    return mem[Int(address)]
}
