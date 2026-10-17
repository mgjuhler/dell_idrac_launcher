import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.net.URL;
import java.security.cert.X509Certificate;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Last-resort downloader used by idrac.ps1 when Windows (Schannel) refuses
 * the iDRAC's old TLS. Java ships its own TLS stack, so together with the
 * relaxed java.security override it can still talk SSLv3/TLS 1.0.
 *
 * Usage: java IdracFetch <url> <destination file>
 * Exit code 0 on success, 1 on any failure (message on stderr).
 *
 * Kept Java 6 compatible (compiled with -source/-target 1.6) so it runs on
 * the bundled JRE 7 as well as on any newer Java.
 */
public class IdracFetch {

    public static void main(String[] args) {
        if (args.length != 2) {
            System.err.println("usage: IdracFetch <url> <file>");
            System.exit(1);
        }
        try {
            fetch(args[0], args[1]);
        } catch (Exception e) {
            System.err.println(e.toString());
            System.exit(1);
        }
    }

    private static void fetch(String url, String dest) throws Exception {
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[] { new TrustAll() }, null);

        HttpsURLConnection conn = (HttpsURLConnection) new URL(url).openConnection();
        conn.setSSLSocketFactory(new AllProtocols(ctx.getSocketFactory()));
        conn.setHostnameVerifier(new HostnameVerifier() {
            public boolean verify(String host, SSLSession session) {
                return true;
            }
        });
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(60000);

        int status = conn.getResponseCode();
        if (status != 200) {
            throw new Exception("HTTP " + status + " for " + url);
        }
        InputStream in = conn.getInputStream();
        OutputStream out = new FileOutputStream(dest);
        try {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        } finally {
            out.close();
            in.close();
        }
    }

    private static class TrustAll implements X509TrustManager {
        public void checkClientTrusted(X509Certificate[] chain, String authType) { }
        public void checkServerTrusted(X509Certificate[] chain, String authType) { }
        public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
    }

    /** Enables every protocol the JVM supports (Java 7 clients default to TLS 1.0 only). */
    private static class AllProtocols extends SSLSocketFactory {
        private final SSLSocketFactory base;

        AllProtocols(SSLSocketFactory base) {
            this.base = base;
        }

        private Socket widen(Socket s) {
            if (s instanceof SSLSocket) {
                SSLSocket ssl = (SSLSocket) s;
                ssl.setEnabledProtocols(ssl.getSupportedProtocols());
            }
            return s;
        }

        public String[] getDefaultCipherSuites() { return base.getDefaultCipherSuites(); }
        public String[] getSupportedCipherSuites() { return base.getSupportedCipherSuites(); }

        public Socket createSocket() throws java.io.IOException {
            return widen(base.createSocket());
        }
        public Socket createSocket(Socket s, String host, int port, boolean autoClose) throws java.io.IOException {
            return widen(base.createSocket(s, host, port, autoClose));
        }
        public Socket createSocket(String host, int port) throws java.io.IOException {
            return widen(base.createSocket(host, port));
        }
        public Socket createSocket(String host, int port, InetAddress local, int localPort) throws java.io.IOException {
            return widen(base.createSocket(host, port, local, localPort));
        }
        public Socket createSocket(InetAddress host, int port) throws java.io.IOException {
            return widen(base.createSocket(host, port));
        }
        public Socket createSocket(InetAddress address, int port, InetAddress local, int localPort) throws java.io.IOException {
            return widen(base.createSocket(address, port, local, localPort));
        }
    }
}
