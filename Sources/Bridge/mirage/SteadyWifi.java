package mirage;

import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Steady Wi-Fi: pause AWDL (awdl0, the AirDrop / iPhone Mirroring / Sidecar radio) while
 * PXPlay runs. AWDL makes the Wi-Fi chip hop to other channels every few hundred
 * milliseconds, which shows up as latency spikes and lost packets in the stream.
 *
 * Turning an interface down needs root. Mirage installs a tiny launchd helper once
 * (macOS asks for the administrator password a single time). PXPlay then only drops a
 * request file with its process id into a shared folder; the helper keeps awdl0 down
 * while that PXPlay process lives and brings it back afterwards if it was up.
 */
final class SteadyWifi {
    static final String LABEL = "io.github.mirage-pxplay.steady-wifi";
    private static volatile String lastError = "";
    private static volatile boolean starting;
    private static volatile boolean hookAdded;

    private SteadyWifi() {}

    /** Prefix for system paths; tests point it at a scratch folder. */
    private static String root() {
        String override = System.getenv("MIRAGE_SYSTEM_ROOT");
        return override == null ? "" : override;
    }

    static Path daemonPlist() {
        return Path.of(root() + "/Library/LaunchDaemons/" + LABEL + ".plist");
    }

    static Path requestFolder() {
        return Path.of(root() + "/Users/Shared/Mirage for PXPlay/steady-wifi");
    }

    static Path requestFile() {
        String user = System.getProperty("user.name", "user").replaceAll("[^A-Za-z0-9._-]", "_");
        return requestFolder().resolve(user + ".pid");
    }

    static boolean helperInstalled() {
        return Files.isRegularFile(daemonPlist());
    }

    static boolean awdlPresent() {
        try {
            return NetworkInterface.getByName("awdl0") != null;
        } catch (Exception unavailable) {
            return false;
        }
    }

    static boolean awdlUp() {
        try {
            NetworkInterface awdl = NetworkInterface.getByName("awdl0");
            return awdl != null && awdl.isUp();
        } catch (Exception unavailable) {
            return false;
        }
    }

    static boolean requested() {
        return Files.exists(requestFile());
    }

    static boolean starting() {
        return starting;
    }

    static String lastError() {
        return lastError;
    }

    /** Asks the helper to pause AWDL for this PXPlay process. Installs the helper first if needed. */
    static void enable(boolean mayInstall) {
        if (starting) return;
        starting = true;
        lastError = "";
        Thread worker = new Thread(() -> {
            try {
                if (!helperInstalled()) {
                    if (!mayInstall) {
                        lastError = Strings.get("wifi.helperMissing");
                        return;
                    }
                    installHelper();
                    if (!helperInstalled()) return;
                }
                writeRequest();
            } catch (Exception failure) {
                lastError = Strings.get("wifi.failed");
                System.err.println("[Mirage] Steady Wi-Fi: " + failure);
            } finally {
                starting = false;
            }
        }, "Mirage Steady Wi-Fi");
        worker.setDaemon(true);
        worker.start();
    }

    private static void writeRequest() throws Exception {
        Path request = requestFile();
        Files.createDirectories(request.getParent());
        Path temp = Files.createTempFile(request.getParent(), ".request", ".tmp");
        Files.writeString(temp, Long.toString(ProcessHandle.current().pid()), StandardCharsets.US_ASCII);
        Files.move(temp, request, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
            java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        if (!hookAdded) {
            hookAdded = true;
            Runtime.getRuntime().addShutdownHook(new Thread(SteadyWifi::disable, "Mirage Steady Wi-Fi stop"));
        }
        System.err.println("[Mirage] Steady Wi-Fi requested for this PXPlay session.");
    }

    /** The one administrator prompt: copies the helper into /Library and loads it. */
    private static void installHelper() throws Exception {
        Path script = Settings.home().resolve("Helper").resolve("install-helper.sh");
        String user = System.getProperty("user.name", "");
        if (!Files.isRegularFile(script) || script.toString().contains("'") || user.contains("'")) {
            lastError = Strings.get("wifi.failed");
            return;
        }
        String shell = "/bin/sh '" + script + "' '" + user + "'";
        String apple = "do shell script \"" + shell.replace("\\", "\\\\").replace("\"", "\\\"")
            + "\" with prompt \"" + Strings.get("wifi.prompt").replace("\\", "\\\\").replace("\"", "\\\"")
            + "\" with administrator privileges";
        Process process = new ProcessBuilder("/usr/bin/osascript", "-e", apple).redirectErrorStream(true).start();
        String output = new String(process.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
        if (process.waitFor() != 0) {
            lastError = output.contains("-128") ? Strings.get("wifi.cancelled") : Strings.get("wifi.failed");
            System.err.println("[Mirage] Steady Wi-Fi helper not installed: " + output);
        }
    }

    /** Removing the request ends the pause within a second; the helper restores AWDL. */
    static void disable() {
        try {
            Files.deleteIfExists(requestFile());
        } catch (Exception ignored) {
        }
    }

    static String status() {
        if (!awdlPresent()) return Strings.get("wifi.none");
        if (starting) return Strings.get("wifi.starting");
        if (!lastError.isEmpty()) return lastError;
        boolean up = awdlUp();
        if (requested()) return up ? Strings.get("wifi.starting") : Strings.get("wifi.on");
        return up ? Strings.get("wifi.off") : Strings.get("wifi.offElsewhere");
    }
}
