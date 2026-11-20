public final class VerifyClassHook {
    public static void main(String[] args) throws Exception {
        var state = Class.forName("com.grill.psplay.gamepad.data.ControllerRemoteState", true,
            VerifyClassHook.class.getClassLoader());
        Object a = state.getDeclaredConstructor().newInstance(), b = state.getDeclaredConstructor().newInstance();
        state.getField("rightX").setInt(b, 20000);
        state.getMethod("copyJoystickState", state).invoke(a, b);
        if (state.getField("rightX").getInt(a) != 20000) throw new AssertionError("stick copy broken");
        System.out.println("Stick state class loaded, verified and copies sticks");
        var cls = Class.forName("com.grill.psplay.video.desktop.renderer.metal.MetalRendererBackend", false,
            VerifyClassHook.class.getClassLoader());
        for (var method : cls.getDeclaredMethods()) {
            if (method.getName().equals("renderAVFrame")) {
                System.out.println("Renderer loaded and method verified: " + method.toGenericString());
                return;
            }
        }
        throw new AssertionError("renderer missing renderAVFrame");
    }
}
