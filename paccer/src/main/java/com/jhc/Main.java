package com.jhc;

import com.android.tools.smali.dexlib2.Opcode;
import com.android.tools.smali.dexlib2.Opcodes;
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11n;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction11x;
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction35c;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedDexFile;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedMethod;
import com.android.tools.smali.dexlib2.dexbacked.DexBackedMethodImplementation;
import com.android.tools.smali.dexlib2.iface.DexFile;
import com.android.tools.smali.dexlib2.iface.MethodImplementation;
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableMethodReference;
import com.android.tools.smali.dexlib2.rewriter.DexRewriter;
import com.android.tools.smali.dexlib2.rewriter.Rewriter;
import com.android.tools.smali.dexlib2.rewriter.RewriterModule;
import com.android.tools.smali.dexlib2.rewriter.Rewriters;
import com.android.tools.smali.dexlib2.writer.io.MemoryDataStore;
import com.android.tools.smali.dexlib2.writer.pool.DexPool;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

public class Main {
    record PatchMethod(
            String name,
            String[] parametersTypes,
            String returnType,
            MethodImplementation replaceWith) {
    }

    record Patch(
            String jarName,
            PatchMethod[] methods) {
    }

    private static Patch[] patches = {
            new Patch("services.jar", new PatchMethod[] {
                    new PatchMethod("isSecureLocked", null, "Z", retFalse()),
                    new PatchMethod("isAllowAudioPlaybackCapture", null, "Z", retTrue()),
                    new PatchMethod("notifyScreenshotListeners", new String[] { "I" }, "Ljava/util/List;",
                            retEmptyList())
            }),
            new Patch("semwifi-service.jar", new PatchMethod[] {
                    new PatchMethod("isSecureLocked", null, "Z", retFalse()),
            }),
            new Patch("miui-services.jar", new PatchMethod[] {
                    new PatchMethod("notAllowCaptureDisplay", null, "Z", retFalse()),
            })
    };

    private static List<String> appliedPatches = new ArrayList<>(3);

    private static MethodImplementation retFalse() {
        MutableMethodImplementation methodImpl = new MutableMethodImplementation(3);
        methodImpl.addInstruction(new BuilderInstruction11n(Opcode.CONST_4, 0, 0));
        methodImpl.addInstruction(new BuilderInstruction11x(Opcode.RETURN, 0));
        return (MethodImplementation) methodImpl;
    }

    private static MethodImplementation retEmptyList() {
        MutableMethodImplementation methodImpl = new MutableMethodImplementation(3);
        methodImpl.addInstruction(new BuilderInstruction35c(
                Opcode.INVOKE_STATIC,
                0,
                0,
                0, 0, 0, 0,
                new ImmutableMethodReference(
                        "Ljava/util/Collections;",
                        "emptyList",
                        Collections.emptyList(),
                        "Ljava/util/List;")));
        methodImpl.addInstruction(new BuilderInstruction11x(
                Opcode.MOVE_RESULT_OBJECT,
                2));
        methodImpl.addInstruction(new BuilderInstruction11x(
                Opcode.RETURN_OBJECT,
                2));
        return (MethodImplementation) methodImpl;
    }

    private static MethodImplementation retTrue() {
        MutableMethodImplementation methodImpl = new MutableMethodImplementation(3);
        methodImpl.addInstruction(new BuilderInstruction11n(Opcode.CONST_4, 0, 1));
        methodImpl.addInstruction(new BuilderInstruction11x(Opcode.RETURN, 0));
        return (MethodImplementation) methodImpl;
    }

    public static void main(String[] args) {
        if (args.length < 4) {
            System.err.println("Usage: paccer <input dex> <output dex> <JAR name> <API>");
            System.exit(1);
        }

        int apiLevel;
        try {
            apiLevel = Integer.parseInt(args[3]);
        } catch (NumberFormatException e) {
            System.err.println("Invalid API level: " + args[3]);
            System.exit(1);
            return;
        }

        try {
            if (!run(args[0], args[1], args[2], apiLevel)) {
                System.exit(1);
            }
        } catch (Exception e) {
            e.printStackTrace();
            System.exit(1);
        }
    }

    private static PatchMethod[] getPatchFromJar(String jarName) {
        for (Patch p : patches) {
            if (p.jarName.equals(jarName)) {
                return p.methods();
            }
        }
        return null;
    }

    private static Boolean run(String dexPath, String outputPath, String jarName, int apiLevel) throws IOException {
        File file = new File(dexPath);
        byte[] fileContent = new byte[(int) file.length()];
        FileInputStream fis = new FileInputStream(file);
        fis.read(fileContent);
        fis.close();
        ByteArrayInputStream bais = new ByteArrayInputStream(fileContent);

        PatchMethod[] methods = getPatchFromJar(jarName);
        if (methods == null) {
            System.err.println("No patch for " + jarName);
            return false;
        }

        ByteArrayOutputStream byteArray = new ByteArrayOutputStream();
        Opcodes opcodes = Opcodes.forApi(apiLevel);

        DexBackedDexFile dex = DexBackedDexFile.fromInputStream(opcodes, bais);
        DexFile rewritten = patchDex(dex, methods);

        MemoryDataStore store = new MemoryDataStore();
        DexPool.writeTo(store, rewritten);

        if (appliedPatches.isEmpty())
            return true;
        for (String p : appliedPatches)
            System.out.println(p);

        byteArray.write(store.getData());

        FileOutputStream fos = new FileOutputStream(outputPath);
        fos.write(byteArray.toByteArray());
        fos.close();
        return true;
    }

    private static DexFile patchDex(DexBackedDexFile input, PatchMethod[] methodsToPatch) {
        DexRewriter rewriter = new DexRewriter(new RewriterModule() {
            @Override
            public Rewriter<MethodImplementation> getMethodImplementationRewriter(Rewriters _rw) {
                return (MethodImplementation impl) -> {
                    if (!(impl instanceof DexBackedMethodImplementation))
                        return impl;

                    DexBackedMethodImplementation methodImpl = (DexBackedMethodImplementation) impl;
                    DexBackedMethod method = methodImpl.method;

                    if (method.getImplementation() == null)
                        return impl;

                    for (PatchMethod methodToPatch : methodsToPatch) {
                        if (method.getName().equals(methodToPatch.name)
                                && (methodToPatch.parametersTypes() == null
                                        || Arrays.equals(methodToPatch.parametersTypes(),
                                                method.getParameterTypes().toArray()))
                                && method.getReturnType().equals(methodToPatch.returnType())) {

                            // System.out.println(
                            //         method.getDefiningClass() + "->" + method.getName() + "("
                            //                 + String.join(",", method.getParameterTypes()) + ")"
                            //                 + method.getReturnType());

                            if (!appliedPatches.contains(methodToPatch.name))
                                appliedPatches.add(methodToPatch.name);

                            return methodToPatch.replaceWith();
                        }
                    }
                    return impl;
                };
            }
        });
        return rewriter.getDexFileRewriter().rewrite(input);
    }
}
