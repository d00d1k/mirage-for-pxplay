package mirage;

import java.util.Locale;
import java.util.ResourceBundle;

/** All twelve PXPlay languages load from Mirage.jar and PXPlay's language tags map to them. */
public final class I18nCheck {
    public static void main(String[] args) {
        String[][] tags = {
            {"en", "Fewer options"}, {"de", null}, {"es", null}, {"fr", null}, {"he", null}, {"iw", null},
            {"it", null}, {"ja", null}, {"ko", null}, {"pt", null}, {"pt-BR", null}, {"ru", "Скрыть дополнительные"},
            {"zh-CN", "收起选项"}, {"zh-TW", "收起選項"}, {"zh-HK", "收起選項"}, {"xx", "Fewer options"},
        };
        ResourceBundle english = ResourceBundle.getBundle("mirage.i18n.strings", Locale.ROOT, I18nCheck.class.getClassLoader(),
            ResourceBundle.Control.getNoFallbackControl(ResourceBundle.Control.FORMAT_PROPERTIES));
        int languages = 0;
        for (String[] tag : tags) {
            Locale locale = Strings.localeFor(tag[0]);
            Strings.use(locale);
            String text = Strings.get("less");
            if (tag[1] != null && !tag[1].equals(text)) throw new AssertionError(tag[0] + " → " + locale + ": " + text);
            for (String key : english.keySet()) {
                if (Strings.get(key.substring("pxplay.".length())).isBlank()) throw new AssertionError(tag[0] + " " + key);
            }
            if (!tag[0].equals("en") && !tag[0].equals("xx") && text.equals(english.getString("pxplay.less"))) {
                throw new AssertionError(tag[0] + " fell back to English");
            }
            languages++;
        }
        System.out.println("Languages: " + languages + " PXPlay language tags map to translated bundles ("
            + english.keySet().size() + " texts each)");
    }
}
