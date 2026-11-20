package mirage;

import java.io.IOException;
import java.io.Reader;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Properties;

/**
 * Mirage settings in one small text file, shared with the installer:
 * ~/Library/Application Support/Mirage for PXPlay/settings.properties
 * (MIRAGE_HOME points elsewhere for tests).
 */
final class Settings {
    enum Style { RECOMMENDED, PICTURE, ORIGINAL, CUSTOM }

    static final int[] STRENGTHS = {50, 70, 85, 100};
    static final int[] STICK_DELAYS = {-1, 0, 60, 100};
    static final int[] WAITS = {0, 4, 8, 12, 18, 25};

    Style style = Style.RECOMMENDED;
    boolean predict = true;
    int strength = 70;
    int smoothing = 2;
    int stick = -1;
    int wait = 0;
    boolean hud = true;
    boolean early = true;
    boolean steadyWifi = false;

    static Path home() {
        String override = System.getenv("MIRAGE_HOME");
        if (override != null && !override.isBlank()) return Path.of(override);
        return Path.of(System.getProperty("user.home"), "Library", "Application Support", "Mirage for PXPlay");
    }

    static Path file() {
        return home().resolve("settings.properties");
    }

    /** The values of a preset; CUSTOM keeps whatever is set. */
    void apply(Style preset) {
        style = preset;
        switch (preset) {
            case RECOMMENDED -> {
                predict = true; strength = 70; smoothing = 2; stick = -1; wait = 0; hud = true; early = true;
            }
            case PICTURE -> {
                predict = false; wait = 12; hud = true; early = true;
            }
            default -> {}
        }
    }

    static Settings load() {
        Settings settings = new Settings();
        Properties values = new Properties();
        try (Reader reader = Files.newBufferedReader(file(), StandardCharsets.UTF_8)) {
            values.load(reader);
        } catch (IOException missing) {
            return settings;
        }
        settings.style = switch (values.getProperty("style", "recommended")) {
            case "picture" -> Style.PICTURE;
            case "original" -> Style.ORIGINAL;
            case "custom" -> Style.CUSTOM;
            default -> Style.RECOMMENDED;
        };
        settings.predict = !"blend".equals(values.getProperty("mode"));
        settings.strength = pick(values, "strength", STRENGTHS, 70);
        settings.smoothing = pick(values, "smoothing", new int[] {0, 1, 2}, 2);
        settings.stick = pick(values, "stick", STICK_DELAYS, -1);
        settings.wait = pick(values, "wait", WAITS, 0);
        settings.hud = !"false".equals(values.getProperty("hud"));
        settings.early = !"false".equals(values.getProperty("early"));
        settings.steadyWifi = "true".equals(values.getProperty("steadyWifi"));
        if (settings.style == Style.RECOMMENDED || settings.style == Style.PICTURE) settings.apply(settings.style);
        return settings;
    }

    void save() {
        Properties values = new Properties();
        values.setProperty("style", style.name().toLowerCase());
        values.setProperty("mode", predict ? "predict" : "blend");
        values.setProperty("strength", Integer.toString(strength));
        values.setProperty("smoothing", Integer.toString(smoothing));
        values.setProperty("stick", Integer.toString(stick));
        values.setProperty("wait", Integer.toString(wait));
        values.setProperty("hud", Boolean.toString(hud));
        values.setProperty("early", Boolean.toString(early));
        values.setProperty("steadyWifi", Boolean.toString(steadyWifi));
        try {
            Files.createDirectories(home());
            Path temp = Files.createTempFile(home(), "settings", ".tmp");
            try (Writer writer = Files.newBufferedWriter(temp, StandardCharsets.UTF_8)) {
                values.store(writer, "Mirage for PXPlay");
            }
            Files.move(temp, file(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException failure) {
            System.err.println("[Mirage] Could not save settings: " + failure.getMessage());
        }
    }

    private static int pick(Properties values, String key, int[] allowed, int fallback) {
        try {
            int value = Integer.parseInt(values.getProperty(key, "").trim());
            for (int candidate : allowed) if (candidate == value) return value;
        } catch (NumberFormatException ignored) {
        }
        return fallback;
    }
}
