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

enum PatchType { RET_EMPTY_LIST, RET_FALSE, RET_TRUE };

struct PatchMethod {
    const char* method_name;
    const char* ret_type = nullptr;
    const char* parent_name = nullptr;

    PatchType patch_type;
};

struct PatchJar {
    const char* jar_name;
    std::vector<PatchMethod> methods;
};

static PatchJar patches[] = {
    {.jar_name = "services.jar",
     .methods =
         {
             {.method_name = "isSecureLocked", .ret_type = "Z", .patch_type = RET_FALSE},
             {.method_name = "notifyScreenshotListeners", .ret_type = "Ljava/util/List;", .patch_type = RET_EMPTY_LIST},
             {.method_name = "isAllowAudioPlaybackCapture", .ret_type = "Z", .patch_type = RET_TRUE},
         }},
    {.jar_name = "semwifi-service.jar",
     .methods =
         {
             {.method_name = "isSecureLocked", .ret_type = "Z", .patch_type = RET_FALSE},
         }},
    {.jar_name = "miui-services.jar",
     .methods =
         {
             {.method_name = "notAllowCaptureDisplay", .ret_type = "Z", .patch_type = RET_FALSE},
         }},
};

bool create_new_img(std::shared_ptr<ir::DexFile> dex_ir, const char* out_dex_filename_) {
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
        fprintf(stderr, "ERROR: Cannot create a new .dex image\n");
        return false;
    }

    if (out_dex_filename_ != nullptr) {
        FILE* out_file = fopen(out_dex_filename_, "wb");
        if (out_file == nullptr) {
            fprintf(stderr, "ERROR: Cannot create output .dex file (%s)\n", out_dex_filename_);
            return false;
        }
        assert(fwrite(new_image, 1, new_image_size, out_file) == new_image_size);
        fclose(out_file);
    }
    allocator.Free(new_image);

    return true;
}

void ret_empty_list(lir::CodeIr& code_ir, ir::Builder& builder) {
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

void ret_empty_list_field(lir::CodeIr& code_ir, ir::Builder& builder) {
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

void ret_const(lir::CodeIr& code_ir, ir::Builder& builder, int v) {
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

ir::EncodedMethod* find_method(std::shared_ptr<ir::DexFile> dex_ir, PatchMethod& p) {
    ir::EncodedMethod* method = nullptr;
    for (auto& ir_method : dex_ir->encoded_methods) {
        // printf("%s->%s%s\n", ir_method->decl->parent->Decl().c_str(), ir_method->decl->name->c_str(),
        //        ir_method->decl->prototype->Signature().c_str());

        if (strcmp(ir_method->decl->name->c_str(), p.method_name) == 0 &&
            (p.ret_type == nullptr ||
             strcmp(ir_method->decl->prototype->return_type->descriptor->c_str(), p.ret_type) == 0) &&
            (p.parent_name == nullptr || strcmp(ir_method->decl->parent->Decl().c_str(), p.parent_name) == 0) &&
            ir_method->code != nullptr

        ) {
            method = ir_method.get();
            break;
        }
    }
    return method;
}

void patch_dex(std::shared_ptr<ir::DexFile> dex_ir, PatchMethod& p, ir::EncodedMethod* method) {
    method->code->registers = method->code->ins_count + 1;

    lir::CodeIr code_ir(method, dex_ir);
    ir::Builder builder(dex_ir);

    auto it = code_ir.instructions.begin();
    while (it != code_ir.instructions.end()) {
        auto instr = *it++;
        code_ir.instructions.Remove(instr);
    }

    switch (p.patch_type) {
        case RET_EMPTY_LIST:
            ret_empty_list(code_ir, builder);
            break;
        case RET_FALSE:
            ret_const(code_ir, builder, 0);
            break;
        case RET_TRUE:
            ret_const(code_ir, builder, 1);
            break;
        default:
            assert(false && "unreachable");
    }
    code_ir.Assemble();
}

int main(int argc, char* argv[]) {
    if (argc <= 3) {
        fprintf(stderr, "Not enough args.\n");
        return 1;
    }
    const char* dex_filename = argv[1];
    const char* out_dex_filename = argv[2];
    const char* jar_name = argv[3];

    PatchJar* patch = nullptr;
    for (auto& p : patches) {
        if (strcmp(p.jar_name, jar_name) == 0) {
            patch = &p;
            break;
        }
    }
    if (patch == nullptr) {
        fprintf(stderr, "ERROR: no patch was found for %s.\n", jar_name);
        return 1;
    }

    struct stat path_stat;
    stat(dex_filename, &path_stat);
    if (!S_ISREG(path_stat.st_mode)) {
        fprintf(stderr, "ERROR: '%s' is not a regular file.\n", dex_filename);
        return 1;
    }

    FILE* in_file = fopen(dex_filename, "rb");
    if (in_file == nullptr) {
        fprintf(stderr, "ERROR: Cannot open input .dex file (%s)\n", dex_filename);
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
    for (auto& p : patch->methods) {
        auto method = find_method(dex_ir, p);
        if (method == nullptr) continue;

        patch_dex(dex_ir, p, method);
        printf("%s\n", p.method_name);
        patched = true;
    }
    fclose(in_file);

    if (patched) {
        if (!create_new_img(dex_ir, out_dex_filename)) return 1;
    }

    return 0;
}
