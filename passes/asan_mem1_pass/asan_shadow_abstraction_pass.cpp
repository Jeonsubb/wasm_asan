#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/InstrTypes.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

namespace {

class AsanShadowAbstractionPass : public PassInfoMixin<AsanShadowAbstractionPass> {
public:
  PreservedAnalyses run(Module &M, ModuleAnalysisManager &) {
    LLVMContext &Ctx = M.getContext();
    Type *I8Ty = Type::getInt8Ty(Ctx);
    Type *I16Ty = Type::getInt16Ty(Ctx);
    Type *I32Ty = Type::getInt32Ty(Ctx);

    FunctionCallee ShadowLoad = M.getOrInsertFunction("__asan_shadow_load8", I8Ty, I32Ty);
    FunctionCallee ShadowStore8 =
        M.getOrInsertFunction("__asan_shadow_store8", Type::getVoidTy(Ctx), I32Ty, I8Ty);
    FunctionCallee ShadowStore16 =
        M.getOrInsertFunction("__asan_shadow_store16", Type::getVoidTy(Ctx), I32Ty, I16Ty);
    FunctionCallee ShadowStore32 =
        M.getOrInsertFunction("__asan_shadow_store32", Type::getVoidTy(Ctx), I32Ty, I32Ty);

    SmallVector<Instruction *, 256> ToErase;
    unsigned RewrittenLoads = 0;
    unsigned RewrittenStores = 0;

    for (Function &F : M) {
      if (F.isDeclaration())
        continue;

      for (BasicBlock &BB : F) {
        for (Instruction &I : BB) {
          if (auto *LI = dyn_cast<LoadInst>(&I)) {
            if (LI->getType() != I8Ty)
              continue;
            Value *ShadowAddr = nullptr;
            if (!getShadowAddrFromPtr(LI->getPointerOperand(), ShadowAddr))
              continue;

            IRBuilder<> B(LI);
            Value *V = B.CreateCall(ShadowLoad, {ShadowAddr}, "asan.shadow.ld");
            LI->replaceAllUsesWith(V);
            ToErase.push_back(LI);
            ++RewrittenLoads;
            continue;
          }

          if (auto *SI = dyn_cast<StoreInst>(&I)) {
            Value *ShadowAddr = nullptr;
            if (!getShadowAddrFromPtr(SI->getPointerOperand(), ShadowAddr))
              continue;

            IRBuilder<> B(SI);
            Value *Stored = SI->getValueOperand();
            Type *StoredTy = Stored->getType();
            if (StoredTy == I8Ty) {
              B.CreateCall(ShadowStore8, {ShadowAddr, Stored});
            } else if (StoredTy == I16Ty) {
              B.CreateCall(ShadowStore16, {ShadowAddr, Stored});
            } else if (StoredTy == I32Ty) {
              B.CreateCall(ShadowStore32, {ShadowAddr, Stored});
            } else {
              continue;
            }
            ToErase.push_back(SI);
            ++RewrittenStores;
            continue;
          }
        }
      }
    }

    for (Instruction *I : ToErase)
      I->eraseFromParent();

    errs() << "[asan-shadow-abstraction] rewritten load8=" << RewrittenLoads
           << " store8=" << RewrittenStores << "\n";

    if (RewrittenLoads == 0 && RewrittenStores == 0)
      return PreservedAnalyses::all();
    return PreservedAnalyses::none();
  }

private:
  static bool getShadowAddrFromPtr(Value *Ptr, Value *&OutAddr) {
    Ptr = Ptr->stripPointerCasts();

    if (auto *I2P = dyn_cast<IntToPtrInst>(Ptr)) {
      Value *IntAddr = I2P->getOperand(0);
      if (isLikelyShadowExpr(IntAddr, 0)) {
        OutAddr = IntAddr;
        return true;
      }
      return false;
    }

    if (auto *CE = dyn_cast<ConstantExpr>(Ptr)) {
      if (CE->getOpcode() == Instruction::IntToPtr) {
        Value *IntAddr = CE->getOperand(0);
        if (isLikelyShadowExpr(IntAddr, 0)) {
          OutAddr = IntAddr;
          return true;
        }
      }
    }

    return false;
  }

  static bool isLikelyShadowExpr(Value *V, unsigned Depth) {
    if (Depth > 12)
      return false;

    if (auto *BO = dyn_cast<BinaryOperator>(V)) {
      unsigned Op = BO->getOpcode();
      if (Op == Instruction::LShr) {
        if (auto *C = dyn_cast<ConstantInt>(BO->getOperand(1)))
          return C->getZExtValue() == 3;
      }
      if (Op == Instruction::Add || Op == Instruction::Sub || Op == Instruction::And ||
          Op == Instruction::Or || Op == Instruction::Xor) {
        Value *L = BO->getOperand(0);
        Value *R = BO->getOperand(1);
        if (isa<ConstantInt>(L) && isLikelyShadowExpr(R, Depth + 1))
          return true;
        if (isa<ConstantInt>(R) && isLikelyShadowExpr(L, Depth + 1))
          return true;
        return isLikelyShadowExpr(L, Depth + 1) || isLikelyShadowExpr(R, Depth + 1);
      }
      return false;
    }

    if (auto *CI = dyn_cast<CastInst>(V))
      return isLikelyShadowExpr(CI->getOperand(0), Depth + 1);

    if (auto *CE = dyn_cast<ConstantExpr>(V)) {
      if (CE->isCast())
        return isLikelyShadowExpr(CE->getOperand(0), Depth + 1);
      if (CE->getOpcode() == Instruction::LShr) {
        if (auto *C = dyn_cast<ConstantInt>(CE->getOperand(1)))
          return C->getZExtValue() == 3;
      }
      if (Instruction::isBinaryOp(CE->getOpcode())) {
        if (CE->getNumOperands() == 2)
          return isLikelyShadowExpr(CE->getOperand(0), Depth + 1) ||
                 isLikelyShadowExpr(CE->getOperand(1), Depth + 1);
      }
    }

    if (auto *PN = dyn_cast<PHINode>(V)) {
      for (Value *In : PN->incoming_values()) {
        if (isLikelyShadowExpr(In, Depth + 1))
          return true;
      }
      return false;
    }

    if (auto *SI = dyn_cast<SelectInst>(V)) {
      return isLikelyShadowExpr(SI->getTrueValue(), Depth + 1) ||
             isLikelyShadowExpr(SI->getFalseValue(), Depth + 1);
    }

    return false;
  }
};

} // namespace

extern "C" LLVM_ATTRIBUTE_WEAK PassPluginLibraryInfo llvmGetPassPluginInfo() {
  return {
      LLVM_PLUGIN_API_VERSION,
      "asan-shadow-abstraction",
      LLVM_VERSION_STRING,
      [](PassBuilder &PB) {
        PB.registerPipelineParsingCallback(
            [](StringRef Name, ModulePassManager &MPM,
               ArrayRef<PassBuilder::PipelineElement>) {
              if (Name == "asan-shadow-abstraction") {
                MPM.addPass(AsanShadowAbstractionPass());
                return true;
              }
              return false;
            });
      }};
}
