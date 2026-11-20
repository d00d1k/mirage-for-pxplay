package mirage;

import java.text.MessageFormat;
import java.util.Locale;
import java.util.MissingResourceException;
import java.util.ResourceBundle;

/** Mirage's texts in the language PXPlay itself is set to (English when unknown). */
final class Strings {
    private static volatile ResourceBundle bundle;

    private Strings() {}

    /** PXPlay's language tag, read only once PXPlay's UI is up (never during start-up). */
    static Locale pxplayLocale() {
        String tag = null;
        try {
            Class<?> manager = Class.forName("com.grill.psplay.localization.LocalizationManager");
            tag = (String) manager.getMethod("getCurrentLocaleLanguageTag").invoke(null);
        } catch (ReflectiveOperationException | LinkageError | RuntimeException unavailable) {
            // Not PXPlay (tests) or a different version: use the system language.
        }
        if (tag == null || tag.isBlank()) tag = Locale.getDefault().toLanguageTag();
        return localeFor(tag);
    }

    static Locale localeFor(String tag) {
        String t = tag.replace('_', '-').toLowerCase(Locale.ROOT);
        if (t.startsWith("zh")) {
            boolean traditional = t.contains("tw") || t.contains("hk") || t.contains("mo") || t.contains("hant");
            return traditional ? Locale.TRADITIONAL_CHINESE : Locale.SIMPLIFIED_CHINESE;
        }
        if (t.startsWith("iw") || t.startsWith("he")) return Locale.of("he");
        return Locale.of(t.split("-")[0]);
    }

    static void use(Locale locale) {
        bundle = ResourceBundle.getBundle("mirage.i18n.strings", locale, Strings.class.getClassLoader(),
            ResourceBundle.Control.getNoFallbackControl(ResourceBundle.Control.FORMAT_PROPERTIES));
    }

    static String get(String key, Object... arguments) {
        ResourceBundle current = bundle;
        if (current == null) {
            use(Locale.getDefault());
            current = bundle;
        }
        String text;
        try {
            text = current.getString("pxplay." + key);
        } catch (MissingResourceException missing) {
            text = key;
        }
        return arguments.length == 0 ? text : MessageFormat.format(text.replace("'", "''"), arguments);
    }
}
