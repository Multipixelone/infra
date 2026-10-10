import github.scarsz.discordsrv.api.events.GameChatMessagePreProcessEvent;
import github.scarsz.discordsrv.dependencies.kyori.adventure.text.Component;
import net.draycia.carbon.paper.integration.dsrv.DSRVListener;
import org.bukkit.event.Event;
import org.bukkit.event.HandlerList;

// Exercise the real pinned Carbon subscriber and DiscordSRV event API without
// registering a bot or sending a message to Discord.
public class CheckCarbonBridge {
    public static void main(String[] args) throws Exception {
        var subscriber = Class.forName("net.draycia.carbon.paper.integration.dsrv.DSRVListener$1");
        var constructor = subscriber.getDeclaredConstructor(DSRVListener.class);
        constructor.setAccessible(true);
        var listener = constructor.newInstance((Object) null);
        var handle = subscriber.getDeclaredMethod("handle", GameChatMessagePreProcessEvent.class);
        handle.setAccessible(true);
        Event original = new Event() {
            public HandlerList getHandlers() { return new HandlerList(); }
        };
        var vanilla = new GameChatMessagePreProcessEvent("global", Component.text("hello"), null, original);
        handle.invoke(listener, vanilla);
        if (!vanilla.isCancelled()) throw new AssertionError("Duplicate Bukkit bridge was not suppressed");
        var carbon = new GameChatMessagePreProcessEvent("global", Component.text("hello"), null, null);
        handle.invoke(listener, carbon);
        if (carbon.isCancelled()) throw new AssertionError("Native Carbon forwarding was suppressed");
        System.out.println("PASS: actual Carbon/DiscordSRV hook suppresses duplicate Bukkit forwarding, keeps native chat");
    }
}
