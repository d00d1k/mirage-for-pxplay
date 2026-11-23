package mirage;

import java.nio.file.Files;
import java.nio.file.Path;
import javafx.animation.PauseTransition;
import javafx.application.Platform;
import javafx.scene.Node;
import javafx.scene.Scene;
import javafx.scene.control.CheckBox;
import javafx.scene.control.ComboBox;
import javafx.scene.control.Hyperlink;
import javafx.scene.control.Label;
import javafx.scene.layout.VBox;
import javafx.stage.Stage;
import javafx.util.Duration;

/**
 * Mirage's block in PXPlay's Video settings, against a stand-in page with PXPlay's node ids.
 * The installer wrote style=picture before start; the panel must show it, let a single
 * option turn the style into Custom, and bring the preset back when chosen again.
 */
public final class FXSettingsCheck {
    public static void main(String[] args) {
        Platform.startup(() -> {
            Label frameGeneration = new Label("Frame generation summary");
            frameGeneration.setId("frameGenerationLabelSummary");
            Label after = new Label("Next PXPlay setting");
            VBox row = new VBox(new Label("Frame generation"), frameGeneration, after);
            VBox content = new VBox(new Label("Video"), row);
            Stage stage = new Stage();
            stage.setScene(new Scene(content, 560, 900));
            stage.setOpacity(0);
            stage.show();

            PauseTransition waitForAgent = new PauseTransition(Duration.seconds(2.0));
            waitForAgent.setOnFinished(event -> {
                try {
                    check(row, frameGeneration, after);
                    stage.close();
                    Platform.exit();
                } catch (Throwable error) {
                    error.printStackTrace();
                    System.exit(1);
                }
            });
            waitForAgent.play();
        });
    }

    @SuppressWarnings("unchecked")
    private static void check(VBox row, Node anchor, Node after) throws Exception {
        Node panel = row.lookup("#mirageSettings");
        if (panel == null) throw new AssertionError("Mirage block missing");
        int at = row.getChildren().indexOf(panel);
        if (at != row.getChildren().indexOf(anchor) + 1 || row.getChildren().indexOf(after) != at + 1) {
            throw new AssertionError("Mirage block must sit right under Frame generation");
        }
        ComboBox<String> style = (ComboBox<String>) panel.lookup("#mirageStyle");
        ComboBox<String> mode = (ComboBox<String>) panel.lookup("#mirageMode");
        ComboBox<String> strength = (ComboBox<String>) panel.lookup("#mirageStrength");
        ComboBox<String> waitBox = (ComboBox<String>) panel.lookup("#mirageWait");
        Node advanced = panel.lookup("#mirageAdvanced");
        Hyperlink more = (Hyperlink) panel.lookup("#mirageMore");
        CheckBox wifi = (CheckBox) panel.lookup("#mirageWifi");
        Label wifiStatus = (Label) panel.lookup("#mirageWifiStatus");
        if (style.getItems().size() != 4) throw new AssertionError("expected 4 styles: " + style.getItems());
        if (style.getSelectionModel().getSelectedIndex() != 1 || mode.getSelectionModel().getSelectedIndex() != 1
                || !waitBox.getValue().startsWith("12")) {
            throw new AssertionError("installer's Best picture not shown: " + style.getValue() + " / " + mode.getValue());
        }
        if (advanced.isVisible()) throw new AssertionError("More options must start folded");
        more.fire();
        if (!advanced.isVisible()) throw new AssertionError("More options did not open");
        if (panel.lookupAll(".combo-box").size() != 6) throw new AssertionError("expected style + 5 option menus");
        if (wifi.isSelected() || wifiStatus.getText().isBlank()) throw new AssertionError("Steady Wi-Fi must be off with a status");

        style.getSelectionModel().select(0);   // Recommended
        if (mode.getSelectionModel().getSelectedIndex() != 0 || !"70%".equals(strength.getValue())
                || !waitBox.getValue().startsWith("0")) {
            throw new AssertionError("Recommended preset not applied: " + mode.getValue() + " " + strength.getValue());
        }
        CheckBox edges = (CheckBox) panel.lookup("#mirageEdges");
        if (edges == null || !edges.isSelected() || edges.isDisabled()) {
            throw new AssertionError("character edges must be on with Recommended");
        }
        strength.getSelectionModel().select(0);   // 50%: a single change makes it Custom
        if (style.getSelectionModel().getSelectedIndex() != 3) throw new AssertionError("style did not turn Custom");
        String saved = Files.readString(Path.of(System.getenv("MIRAGE_HOME"), "settings.properties"));
        if (!saved.contains("style=custom") || !saved.contains("strength=50") || !saved.contains("edges=true")) {
            throw new AssertionError("settings not saved: " + saved);
        }
        System.out.println("Settings: Mirage block under Frame generation, installer style shown, More options folded, "
            + "Recommended preset applied (character edges on), single change → Custom (saved), Steady Wi-Fi off: " + wifiStatus.getText());
    }
}
