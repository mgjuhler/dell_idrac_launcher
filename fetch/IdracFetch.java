import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.Socket;
import java.net.URL;
import java.security.cert.X509Certificate;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSession;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Helper for idrac.ps1.
 *
 * Download mode is the last-resort downloader used when Windows (Schannel)
 * refuses the iDRAC's old TLS. Java ships its own TLS stack, so together
 * with the relaxed java.security override it can still talk SSLv3/TLS 1.0.
 *
 * Extract mode unpacks the native DLLs from a library jar. Windows 7 runs
 * PowerShell 2.0 on .NET 3.5, which has no zip support of its own.
 *
 * Usage: java IdracFetch <url> <destination file>
 *        java IdracFetch --extract-dlls <jar> <destination dir>
 * Exit code 0 on success, 1 on any failure (message on stderr).
 *
 * Kept Java 6 compatible (compiled with -source/-target 1.6) so it runs on
 * the bundled JRE 7 as well as on any newer Java.
 */
public class IdracFetch {

    public static void main(String[] args) {
        try {
            if (args.length == 3 && args[0].equals("--extract-dlls")) {
                extractDlls(args[1], args[2]);
            } else if (args.length == 2) {
                fetch(args[0], args[1]);
            } else {
                System.err.println("usage: IdracFetch <url> <file> | --extract-dlls <jar> <dir>");
                System.exit(1);
            }
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
            copy(in, out);
        } finally {
            out.close();
            in.close();
        }
    }

    private static void extractDlls(String jar, String dir) throws Exception {
        ZipFile zip = new ZipFile(jar);
        int count = 0;
        try {
            Enumeration<? extends ZipEntry> entries = zip.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = new File(entry.getName()).getName();
                if (entry.isDirectory() || !name.toLowerCase().endsWith(".dll")) {
                    continue;
                }
                InputStream in = zip.getInputStream(entry);
                OutputStream out = new FileOutputStream(new File(dir, name));
                try {
                    copy(in, out);
                } finally {
                    out.close();
                    in.close();
                }
                count++;
            }
        } finally {
            zip.close();
        }
        if (count == 0) {
            throw new Exception("no DLL files in " + jar);
        }
    }

    private static void copy(InputStream in, OutputStream out) throws java.io.IOException {
        byte[] buf = new byte[65536];
        int n;
        while ((n = in.read(buf)) > 0) {
            out.write(buf, 0, n);
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
