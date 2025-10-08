#include <sys/stat.h>

#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "slicer/code_ir.h"
#include "slicer/dex_format.h"
#include "slicer/dex_ir_builder.h"
#include "slicer/reader.h"
#include "slicer/writer.h"

enum class PatchType { RET_EMPTY_LIST, RET_FALSE, RET_TRUE };

static inline bool patchTypeFromStr(const char* str, PatchType& t) {
    if (strcmp(str, "RET_EMPTY_LIST") == 0) t = PatchType::RET_EMPTY_LIST;
    else if (strcmp(str, "RET_TRUE") == 0) t = PatchType::RET_TRUE;
    else if (strcmp(str, "RET_FALSE") == 0) t = PatchType::RET_FALSE;
    else return false;
    return true;
}

static inline const char* retTypeFromPatch(PatchType t) {
    switch (t) {
        case PatchType::RET_EMPTY_LIST:
            return "Ljava/util/List;";
        case PatchType::RET_FALSE:
        case PatchType::RET_TRUE:
            return "Z";
        default:
            assert(false && "unreachable");
    }
}

struct PatchMethod {
    std::string method_name;
    std::string parent_name;
    PatchType patch_type;
};

static std::vector<PatchMethod> parsePatchesArg(const char* list) {
    std::vector<PatchMethod> ps;
    int i = 0;
    for (;;) {
        PatchMethod pm;
        int j = 0;
        bool type_turn = false;
        std::string patch_type_str;
        for (;;) {
            char c = list[i + j++];
            if (c == '\0') break;
            if (c == ';') break;
            if (isspace(c)) continue;
            if (c == ':') {
                type_turn = true;
                continue;
            }
            if (type_turn) patch_type_str.push_back(c);
            else pm.method_name.push_back(c);
        }
        if (pm.method_name.empty() || patch_type_str.empty()) break;
        if (!patchTypeFromStr(patch_type_str.c_str(), pm.patch_type)) {
            fprintf(stderr, "Invalid patch type '%s'\n", patch_type_str.c_str());
            return {};
        }
        ps.push_back(std::move(pm));
        i += j;
    }

    return ps;
}

bool createNewImg(std::shared_ptr<ir::DexFile> dex_ir, const char* out_dex_filename) {
    struct Allocator : public dex::Writer::Allocator {
        virtual void* Allocate(size_t size) { return ::malloc(size); }
        virtual void Free(void* ptr) { ::free(ptr); }
    };

    size_t new_image_size = 0;
    dex::u1* new_image = nullptr;
    Allocator allocator;

    dex::Writer writer(dex_ir);
    new_image = writer.CreateImage(&allocator, &new_image_size);

    if (new_image == nullptr) {
        fprintf(stderr, "Cannot create a new .dex image\n");
        return false;
    }

    FILE* out_file = fopen(out_dex_filename, "wb");
    if (out_file == nullptr) {
        fprintf(stderr, "Cannot create output .dex file (%s)\n", out_dex_filename);
        return false;
    }
    assert(fwrite(new_image, 1, new_image_size, out_file) == new_image_size);
    fclose(out_file);
    allocator.Free(new_image);

    return true;
}

void retEmptyList(lir::CodeIr& code_ir, ir::Builder& builder) {
    ir::MethodDecl* mdecl =
        builder.GetMethodDecl(builder.GetAsciiString("emptyList"),
                              builder.GetProto(builder.GetType("Ljava/util/List;"), builder.GetTypeList({})),
                              builder.GetType("Ljava/util/Collections;"));

    auto* invokeOp = code_ir.Alloc<lir::Bytecode>();
    invokeOp->opcode = dex::OP_INVOKE_STATIC;
    invokeOp->operands.push_back(code_ir.Alloc<lir::VRegList>());
    invokeOp->operands.push_back(code_ir.Alloc<lir::Method>(mdecl, mdecl->orig_index));

    auto* moveOp = code_ir.Alloc<lir::Bytecode>();
    moveOp->opcode = dex::OP_MOVE_RESULT_OBJECT;
    moveOp->operands.push_back(code_ir.Alloc<lir::VReg>(1));

    auto* retOp = code_ir.Alloc<lir::Bytecode>();
    retOp->opcode = dex::OP_RETURN_OBJECT;
    retOp->operands.push_back(code_ir.Alloc<lir::VReg>(1));

    code_ir.instructions.insert(code_ir.instructions.begin(), retOp);
    code_ir.instructions.insert(code_ir.instructions.begin(), moveOp);
    code_ir.instructions.insert(code_ir.instructions.begin(), invokeOp);
}

void retEmptyListField(lir::CodeIr& code_ir, ir::Builder& builder) {
    auto* sgetOp = code_ir.Alloc<lir::Bytecode>();
    sgetOp->opcode = dex::OP_SGET_OBJECT;
    sgetOp->operands.push_back(code_ir.Alloc<lir::VReg>(0));

    auto fieldDecl =
        builder.GetFieldDecl(builder.GetAsciiString("EMPTY_LIST"), builder.GetType("Ljava/util/Collections;"),
                             builder.GetType("Ljava/util/List;"));

    auto* field = code_ir.Alloc<lir::Field>(fieldDecl, fieldDecl->orig_index);
    sgetOp->operands.push_back(field);

    auto* retOp = code_ir.Alloc<lir::Bytecode>();
    retOp->opcode = dex::OP_RETURN_OBJECT;
    retOp->operands.push_back(code_ir.Alloc<lir::VReg>(0));

    code_ir.instructions.insert(code_ir.instructions.begin(), retOp);
    code_ir.instructions.insert(code_ir.instructions.begin(), sgetOp);
}

void retConst(lir::CodeIr& code_ir, ir::Builder& builder, int v) {
    lir::Bytecode* retOp = code_ir.Alloc<lir::Bytecode>();
    retOp->opcode = dex::OP_RETURN;
    retOp->operands.push_back(code_ir.Alloc<lir::VReg>(0));

    lir::Bytecode* constOp = code_ir.Alloc<lir::Bytecode>();
    constOp->opcode = dex::OP_CONST_4;
    constOp->operands.push_back(code_ir.Alloc<lir::VReg>(0));
    constOp->operands.push_back(code_ir.Alloc<lir::Const32>(v));

    code_ir.instructions.insert(code_ir.instructions.begin(), retOp);
    code_ir.instructions.insert(code_ir.instructions.begin(), constOp);
}

ir::EncodedMethod* findMethod(std::shared_ptr<ir::DexFile> dex_ir, PatchMethod& p) {
    ir::EncodedMethod* method = nullptr;
    for (auto& ir_method : dex_ir->encoded_methods) {
        // printf("%s->%s%s\n", ir_method->decl->parent->Decl().c_str(), ir_method->decl->name->c_str(),
        //        ir_method->decl->prototype->Signature().c_str());

        if (strcmp(ir_method->decl->name->c_str(), p.method_name.c_str()) == 0 &&
            strcmp(ir_method->decl->prototype->return_type->descriptor->c_str(), retTypeFromPatch(p.patch_type)) == 0 &&
            (p.parent_name.empty() || strcmp(ir_method->decl->parent->Decl().c_str(), p.parent_name.c_str()) == 0) &&
            ir_method->code != nullptr

        ) {
            method = ir_method.get();
            break;
        }
    }
    return method;
}

void patchDex(std::shared_ptr<ir::DexFile> dex_ir, PatchMethod& p, ir::EncodedMethod* method) {
    method->code->registers = method->code->ins_count + 1;

    lir::CodeIr code_ir(method, dex_ir);
    ir::Builder builder(dex_ir);

    auto it = code_ir.instructions.begin();
    while (it != code_ir.instructions.end()) {
        auto instr = *it++;
        code_ir.instructions.Remove(instr);
    }

    switch (p.patch_type) {
        case PatchType::RET_EMPTY_LIST:
            retEmptyList(code_ir, builder);
            break;
        case PatchType::RET_FALSE:
            retConst(code_ir, builder, 0);
            break;
        case PatchType::RET_TRUE:
            retConst(code_ir, builder, 1);
            break;
        default:
            assert(false && "unreachable");
    }
    code_ir.Assemble();
}

static void printUsage(const char* program_name) {
    fprintf(stderr,
            "Usage:\n  %s <in dex> <out dex> <patch definitions>\n"
            "  Example patch defs.:\n"
            "    methodName1:RET_FALSE;\n"
            "    methodName2:RET_TRUE;\n"
            "    methodName3:RET_EMPTY_LIST;\n",
            program_name);
}

int main(int argc, char* argv[]) {
    if (argc != 4) {
        printUsage(argv[0]);
        return 1;
    }
    const char* dex_filename = argv[1];
    const char* out_dex_filename = argv[2];
    auto patches = parsePatchesArg(argv[3]);
    if (patches.empty()) {
        printUsage(argv[0]);
        return 1;
    }

    struct stat path_stat;
    stat(dex_filename, &path_stat);
    if (!S_ISREG(path_stat.st_mode)) {
        fprintf(stderr, "'%s' is not a regular file.\n", dex_filename);
        return 1;
    }

    FILE* in_file = fopen(dex_filename, "rb");
    if (in_file == nullptr) {
        fprintf(stderr, "Cannot open input .dex file (%s)\n", dex_filename);
        return 1;
    }

    fseek(in_file, 0, SEEK_END);
    size_t in_size = ftell(in_file);

    std::unique_ptr<dex::u1[]> in_buff(new dex::u1[in_size]);

    fseek(in_file, 0, SEEK_SET);
    assert(fread(in_buff.get(), 1, in_size, in_file) == in_size);

    dex::Reader reader(in_buff.get(), in_size);
    reader.CreateFullIr();
    auto dex_ir = reader.GetIr();

    bool patched = false;
    for (auto& p : patches) {
        auto method = findMethod(dex_ir, p);
        if (method == nullptr) {
            printf("Method not found: %s()%s\n", p.method_name.c_str(), retTypeFromPatch(p.patch_type));
            continue;
        }
        patchDex(dex_ir, p, method);
        printf("Patched: %s\n", p.method_name.c_str());
        patched = true;
    }
    fclose(in_file);

    if (patched) {
        if (!createNewImg(dex_ir, out_dex_filename)) return 1;
    }

    return 0;
}
