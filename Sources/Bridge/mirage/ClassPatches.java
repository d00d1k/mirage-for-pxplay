package mirage;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeBuilder;
import java.lang.classfile.CodeElement;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.Label;
import java.lang.classfile.Opcode;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;

/**
 * In-memory edits of two PXPlay 3.2.0 classes, called by the agent while the class loads.
 * The agent has already matched the exact class bytes (size and FNV-1a hash); nothing is
 * written to disk and no PXPlay code ships with Mirage.
 */
public final class ClassPatches {
    private static final ClassDesc BACKEND =
        ClassDesc.of("com.grill.psplay.video.desktop.renderer.metal.MetalRendererBackend");
    private static final ClassDesc METAL = ClassDesc.of("com.grill.streamutils.metal.MetalRenderer");
    private static final ClassDesc FRAME = ClassDesc.of("org.bytedeco.ffmpeg.avutil.AVFrame");
    private static final ClassDesc PACER = ClassDesc.of("com.grill.psplay.video.pacing.FramePacingHandler");
    private static final ClassDesc STATE = ClassDesc.of("com.grill.psplay.gamepad.data.ControllerRemoteState");
    private static final ClassDesc BRIDGE = ClassDesc.of("mirage.MirageBridge");
    private static final MethodTypeDesc RENDER = MethodTypeDesc.of(ConstantDescs.CD_void, FRAME);
    private static final MethodTypeDesc PIXEL_BUFFER = MethodTypeDesc.of(ConstantDescs.CD_long, FRAME);
    private static final MethodTypeDesc ENABLED = MethodTypeDesc.of(ConstantDescs.CD_boolean);
    private static final MethodTypeDesc PREFETCH =
        MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Object, ConstantDescs.CD_long);
    private static final MethodTypeDesc COPY = MethodTypeDesc.of(ConstantDescs.CD_void, STATE);
    private static final MethodTypeDesc STICKS = MethodTypeDesc.of(ConstantDescs.CD_void,
        ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int, ConstantDescs.CD_int);

    private ClassPatches() {}

    /** Returns the edited class, or null to keep the original. */
    public static byte[] patch(String internalName, byte[] original) {
        try {
            return switch (internalName) {
                case "com/grill/psplay/video/desktop/renderer/metal/MetalRendererBackend" -> earlyStart(original);
                case "com/grill/psplay/gamepad/data/ControllerRemoteState" -> stickReport(original);
                default -> null;
            };
        } catch (RuntimeException failure) {
            System.err.println("[Mirage] Class edit skipped: " + failure);
            return null;
        }
    }

    /**
     * MetalRendererBackend.renderAVFrame: right before the decoded frame goes to the frame
     * pacer, hand its pixel buffer to Mirage so RIFE can start before the frame is due.
     */
    static byte[] earlyStart(byte[] original) {
        ClassFile file = ClassFile.of();
        int[] found = {0};
        byte[] patched = file.transformClass(file.parse(original), ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("renderAVFrame") && m.methodTypeSymbol().equals(RENDER),
            (builder, element) -> {
                if (element instanceof InvokeInstruction call && call.opcode() == Opcode.INVOKEVIRTUAL
                        && call.owner().asSymbol().equals(PACER) && call.name().equalsString("submitFrame")
                        && call.typeSymbol().equals(RENDER)) {
                    Label skip = builder.newLabel();
                    builder.invokestatic(BRIDGE, "rifePrefetchEnabled", ENABLED)
                        .ifeq(skip)
                        .aload(0).getfield(BACKEND, "metalRenderer", METAL)
                        .aload(1).invokestatic(BACKEND, "pixelBufferOf", PIXEL_BUFFER)
                        .invokestatic(BRIDGE, "prefetchVideoFrame", PREFETCH)
                        .labelBinding(skip);
                    found[0]++;
                }
                builder.with(element);
            }));
        if (found[0] != 1) throw new IllegalStateException("expected one decoded-frame submission, found " + found[0]);
        return patched;
    }

    /**
     * ControllerRemoteState.copyJoystickState: report the stick state PXPlay sends to the
     * console, so prediction can ease off when the camera stick is released or reversed.
     */
    static byte[] stickReport(byte[] original) {
        ClassFile file = ClassFile.of();
        int[] found = {0};
        byte[] patched = file.transformClass(file.parse(original), ClassTransform.transformingMethodBodies(
            m -> m.methodName().equalsString("copyJoystickState") && m.methodTypeSymbol().equals(COPY),
            new CodeTransform() {
                private boolean done;

                @Override
                public void accept(CodeBuilder builder, CodeElement element) {
                    if (!done) {
                        done = true;
                        found[0]++;
                        builder.aload(1).getfield(STATE, "rightX", ConstantDescs.CD_int)
                            .aload(1).getfield(STATE, "rightY", ConstantDescs.CD_int)
                            .aload(1).getfield(STATE, "leftX", ConstantDescs.CD_int)
                            .aload(1).getfield(STATE, "leftY", ConstantDescs.CD_int)
                            .invokestatic(BRIDGE, "stickInput", STICKS);
                    }
                    builder.with(element);
                }
            }));
        if (found[0] != 1) throw new IllegalStateException("copyJoystickState not found");
        return patched;
    }
}
