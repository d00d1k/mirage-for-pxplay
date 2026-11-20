package mirage;

import java.util.List;
import java.util.function.IntConsumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javafx.animation.KeyFrame;
import javafx.animation.Timeline;
import javafx.application.Platform;
import javafx.geometry.Insets;
import javafx.scene.Node;
import javafx.scene.Parent;
import javafx.scene.Scene;
import javafx.scene.control.CheckBox;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Hyperlink;
import javafx.scene.control.Label;
import javafx.scene.layout.Pane;
import javafx.scene.layout.VBox;
import javafx.stage.Window;
import javafx.util.Duration;

/**
 * The Java side of Mirage inside PXPlay: applies the saved settings to the agent and adds
 * a "Mirage" block under Frame generation in PXPlay's Video settings.
 */
public final class MirageBridge {
    private static final String PANEL = "mirageSettings";
    private static final Pattern SHARE = Pattern.compile("(\\d+)%");
    private static volatile Settings settings = new Settings();
    private static volatile boolean nativesReady;

    private MirageBridge() {}

    private static native String lastStatus();
    private static native void selectFG(int engine, int profile, int waitMs);
    public static native boolean rifePrefetchEnabled();
    public static native void prefetchVideoFrame(Object renderer, long pixelBuffer);
    private static native void setRifePrefetch(boolean enabled);
    private static native void setRifeHudProtection(boolean enabled);
    private static native void setRifeExtrapolation(boolean enabled);
    private static native void setExtrapolationTuning(int strength, int damping, int stickDelayMs);
    private static native void stickInputNative(int rightX, int rightY, int leftX, int leftY);

    /** Called from PXPlay's controller code (edited in memory) with the stick state sent to the console. */
    public static void stickInput(int rightX, int rightY, int leftX, int leftY) {
        if (!nativesReady) return;
        try {
            stickInputNative(rightX, rightY, leftX, leftY);
        } catch (Throwable unavailable) {
            nativesReady = false;
        }
    }

    /** Called once by the agent when the Java runtime starts. */
    public static void begin() {
        settings = Settings.load();
        applyToEngine();
        nativesReady = true;
        if (settings.steadyWifi) SteadyWifi.enable(false);
        Thread startup = new Thread(() -> {
            for (int i = 0; i < 240; i++) {
                try {
                    Platform.runLater(MirageBridge::observeSettings);
                    return;
                } catch (IllegalStateException notStarted) {
                    try {
                        Thread.sleep(250);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        return;
                    }
                }
            }
        }, "Mirage settings");
        startup.setDaemon(true);
        startup.start();
    }

    static void applyToEngine() {
        Settings s = settings;
        selectFG(s.style == Settings.Style.ORIGINAL ? 0 : 2, 0, s.wait);
        setRifeExtrapolation(s.predict);
        setExtrapolationTuning(s.strength, s.smoothing, s.stick);
        setRifeHudProtection(s.hud);
        setRifePrefetch(s.early);
        System.err.println("[Mirage] Style " + s.style.name().toLowerCase() + ", " + (s.predict ? "prediction" : "blend")
            + ", wait " + s.wait + " ms.");
    }

    private static void observeSettings() {
        Timeline timer = new Timeline(new KeyFrame(Duration.millis(400), event -> updateSettings()));
        timer.setCycleCount(Timeline.INDEFINITE);
        timer.play();
    }

    private static void updateSettings() {
        for (Window window : Window.getWindows()) {
            Scene scene = window.getScene();
            if (!window.isShowing() || scene == null) continue;
            Parent root = scene.getRoot();
            Node anchor = root.lookup("#frameGenerationLabelSummary");
            if (anchor == null || !(anchor.getParent() instanceof Pane row)) continue;
            Node existing = row.lookup("#" + PANEL);
            if (existing == null) {
                Strings.use(Strings.pxplayLocale());
                existing = new Panel();
                existing.setId(PANEL);
                row.getChildren().add(row.getChildren().indexOf(anchor) + 1, existing);
            }
            if (existing instanceof Panel panel) panel.refresh(lastStatus());
        }
    }

    private static Label note(String text) {
        Label label = new Label(text);
        label.setWrapText(true);
        label.setMaxWidth(420);
        label.getStyleClass().add("settingsAdditionalInfo");
        return label;
    }

    private static String lastStream(String generation) {
        if (generation.isBlank()) return "";
        if (generation.contains("Mirage")) {
            Matcher share = SHARE.matcher(generation);
            return share.find() ? Strings.get("last.share", share.group(1)) : Strings.get("last.mirage");
        }
        if (generation.contains("PXPlay")) return Strings.get("last.pxplay");
        return Strings.get("last.off");
    }

    private static final class Panel extends VBox {
        private final ComboBox<String> style = combo("mirageStyle", "style.recommended", "style.picture",
            "style.original", "style.custom");
        private final Label styleNote = note("");
        private final Hyperlink more = new Hyperlink(Strings.get("more"));
        private final VBox advanced = new VBox(6);
        private final ComboBox<String> mode = combo("mirageMode", "mode.predict", "mode.blend");
        private final ComboBox<String> strength = combo("mirageStrength");
        private final ComboBox<String> smoothing = combo("mirageSmoothing", "smoothing.0", "smoothing.1", "smoothing.2");
        private final ComboBox<String> stick = combo("mirageStick", "stick.off", "stick.0", "stick.60", "stick.100");
        private final ComboBox<String> waitBox = combo("mirageWait");
        private final CheckBox hud = new CheckBox(Strings.get("hud"));
        private final CheckBox early = new CheckBox(Strings.get("early"));
        private final CheckBox wifi = new CheckBox(Strings.get("wifi"));
        private final Label wifiStatus = note("");
        private final Label status = note("");
        private boolean updating;

        Panel() {
            super(7);
            setFillWidth(false);
            setPadding(new Insets(6, 0, 4, 0));
            for (int value : Settings.STRENGTHS) strength.getItems().add(value + "%");
            for (int value : Settings.WAITS) waitBox.getItems().add(Strings.get("wait.ms", value));
            Label title = new Label(Strings.get("title"));
            title.getStyleClass().add("settingsSubHeader");
            more.setId("mirageMore");
            more.setOnAction(event -> showAdvanced(!advanced.isVisible()));
            advanced.setId("mirageAdvanced");
            hud.setId("mirageHud");
            early.setId("mirageEarly");
            wifi.setId("mirageWifi");
            wifiStatus.setId("mirageWifiStatus");
            status.setId("mirageStatus");
            advanced.getChildren().addAll(
                note(Strings.get("mode")), mode,
                note(Strings.get("strength")), strength,
                note(Strings.get("smoothing")), smoothing,
                note(Strings.get("stick")), stick,
                note(Strings.get("wait")), waitBox,
                hud, early);
            showAdvanced(settings.style == Settings.Style.CUSTOM);
            getChildren().addAll(title, style, styleNote, more, advanced, wifi, note(Strings.get("wifi.note")),
                wifiStatus, status, note(Strings.get("apply")));
            show();

            style.getSelectionModel().selectedIndexProperty().addListener((o, before, after) -> {
                if (updating || after.intValue() < 0) return;
                Settings.Style chosen = Settings.Style.values()[after.intValue()];
                if (chosen == Settings.Style.CUSTOM) settings.style = chosen; else settings.apply(chosen);
                if (chosen == Settings.Style.CUSTOM) showAdvanced(true);
                changed();
            });
            onPick(mode, index -> settings.predict = index == 0);
            onPick(strength, index -> settings.strength = Settings.STRENGTHS[index]);
            onPick(smoothing, index -> settings.smoothing = index);
            onPick(stick, index -> settings.stick = Settings.STICK_DELAYS[index]);
            onPick(waitBox, index -> settings.wait = Settings.WAITS[index]);
            hud.selectedProperty().addListener((o, before, after) -> custom(() -> settings.hud = after));
            early.selectedProperty().addListener((o, before, after) -> custom(() -> settings.early = after));
            wifi.selectedProperty().addListener((o, before, after) -> {
                if (updating) return;
                settings.steadyWifi = after;
                settings.save();
                if (after) SteadyWifi.enable(true); else SteadyWifi.disable();
            });
        }

        private static ComboBox<String> combo(String id, String... keys) {
            ComboBox<String> box = new ComboBox<>();
            box.setId(id);
            for (String key : keys) box.getItems().add(Strings.get(key));
            return box;
        }

        private void onPick(ComboBox<String> box, IntConsumer setter) {
            box.getSelectionModel().selectedIndexProperty().addListener((o, before, after) -> {
                if (after.intValue() >= 0) custom(() -> setter.accept(after.intValue()));
            });
        }

        /** A change to a single option turns the style into "Custom". */
        private void custom(Runnable change) {
            if (updating) return;
            change.run();
            settings.style = Settings.Style.CUSTOM;
            changed();
        }

        private void changed() {
            settings.save();
            applyToEngine();
            show();
        }

        private void showAdvanced(boolean visible) {
            advanced.setVisible(visible);
            advanced.setManaged(visible);
            more.setText(Strings.get(visible ? "less" : "more"));
        }

        /** Puts the current settings into the controls without firing their listeners. */
        private void show() {
            updating = true;
            Settings s = settings;
            style.getSelectionModel().select(s.style.ordinal());
            styleNote.setText(Strings.get(switch (s.style) {
                case RECOMMENDED -> "style.recommended.note";
                case PICTURE -> "style.picture.note";
                case ORIGINAL -> "style.original.note";
                case CUSTOM -> "style.custom.note";
            }));
            mode.getSelectionModel().select(s.predict ? 0 : 1);
            strength.getSelectionModel().select(indexOf(Settings.STRENGTHS, s.strength));
            smoothing.getSelectionModel().select(s.smoothing);
            stick.getSelectionModel().select(indexOf(Settings.STICK_DELAYS, s.stick));
            waitBox.getSelectionModel().select(indexOf(Settings.WAITS, s.wait));
            for (Node node : List.of(strength, smoothing, stick)) node.setDisable(!s.predict);
            hud.setSelected(s.hud);
            early.setSelected(s.early);
            wifi.setSelected(s.steadyWifi);
            updating = false;
        }

        void refresh(String nativeStatus) {
            String[] parts = nativeStatus.split("\n", -1);
            String last = lastStream(parts.length > 1 ? parts[1] : "");
            if (!last.equals(status.getText())) status.setText(last);
            status.setVisible(!last.isEmpty());
            status.setManaged(!last.isEmpty());
            String wifiText = SteadyWifi.status();
            if (!wifiText.equals(wifiStatus.getText())) wifiStatus.setText(wifiText);
            // The password dialog was cancelled or the helper failed: show the switch as off.
            if (wifi.isSelected() && !SteadyWifi.starting() && !SteadyWifi.requested()
                    && !SteadyWifi.lastError().isEmpty()) {
                settings.steadyWifi = false;
                settings.save();
                updating = true;
                wifi.setSelected(false);
                updating = false;
            }
        }

        private static int indexOf(int[] values, int value) {
            for (int i = 0; i < values.length; i++) if (values[i] == value) return i;
            return 0;
        }
    }
}
