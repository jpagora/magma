vcl 4.0;

import std;

# =============================================================================
# VARNISH VCL OTIMIZADO - jpagora.com
# Servidor: 24GB RAM / 8 vCPUs | WordPress + WP Rocket + Newspaper Theme
# =============================================================================

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .first_byte_timeout = 300s;
    .connect_timeout = 5s;
    .between_bytes_timeout = 5s;

    # Health check - Varnish verifica se o backend esta vivo
    .probe = {
        .url = "/wp-login.php";
        .timeout = 5s;
        .interval = 15s;
        .window = 5;
        .threshold = 3;
    }
}

acl purger {
    "localhost";
    "127.0.0.1";
    "172.17.0.1";
}

# =============================================================================
# vcl_recv - Requisicoes chegando
# =============================================================================
sub vcl_recv {
    if (req.restarts > 0) {
        set req.hash_always_miss = true;
    }

    # --- NORMALIZACAO DE URL ---
    if (req.url ~ "(?i)^https?://") {
        set req.url = regsub(req.url, "(?i)^https?://[^/]+", "");
    }
    if (req.url == "") {
        set req.url = "/";
    }

    # --- LOGICA DE PURGE ---
    if (req.method == "PURGE") {
        if (client.ip !~ purger) {
            return (synth(405, "Method not allowed"));
        }

        # Limpeza por Tags (Plugin Varnish HTTP Purge)
        if (req.http.X-Purge-Method == "tags" && req.http.X-Cache-Tags-Pattern) {
            ban("obj.http.X-Cache-Tags ~ " + req.http.X-Cache-Tags-Pattern);
            return (synth(200, "Banned by tags pattern"));
        }

        # Limpeza por Tags Simples
        if (req.http.X-Cache-Tags) {
            ban("obj.http.X-Cache-Tags ~ " + req.http.X-Cache-Tags);
            return (synth(200, "Banned by tags"));
        }

        # Limpeza exata por URL (ban limpa todas as variantes: mobile + desktop)
        ban("req.http.host == " + req.http.host + " && req.url == " + req.url);
        return (synth(200, "Purged"));
    }

    # --- BAN para limpeza em massa (WP Rocket / plugins) ---
    if (req.method == "BAN") {
        if (client.ip !~ purger) {
            return (synth(405, "Method not allowed"));
        }
        ban("req.http.host == " + req.http.host + " && req.url ~ " + req.url);
        return (synth(200, "Banned"));
    }

    # Metodos nao padrao vao para pipe
    if (req.method != "GET" &&
        req.method != "HEAD" &&
        req.method != "PUT" &&
        req.method != "POST" &&
        req.method != "TRACE" &&
        req.method != "OPTIONS" &&
        req.method != "DELETE") {
          return (pipe);
    }

    # Somente GET e HEAD sao cacheados
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    set req.http.grace = "none";

    # --- NORMALIZACAO DE USER-AGENT (Device Detection) ---
    # Newspaper Theme gera HTML diferente para mobile/desktop
    if (req.http.User-Agent ~ "(?i)(android|bb\d+|meego).+mobile|avantgo|bada/|blackberry|blazer|compal|elaine|fennec|hiptop|iemobile|ip(hone|od)|iris|kindle|lge |maemo|midp|mmp|mobile.+firefox|netfront|opera m(ob|in)i|palm( os)?|phone|p(ixi|rim)|plucker|pocket|psp|series(4|6)0|symbian|treo|up.(browser|link)|vodafone|wap|windows ce|xda|xiino") {
        set req.http.X-UA-Device = "mobile";
    } else {
        set req.http.X-UA-Device = "desktop";
    }

    # --- BYPASS OBRIGATORIO (nunca cachear) ---
    if (req.url ~ "^/wp-admin" ||
        req.url ~ "^/wp-login\.php" ||
        req.url ~ "^/wp-cron\.php" ||
        req.url ~ "^/wp-json/" ||
        req.url ~ "xmlrpc\.php" ||
        req.url ~ "^/feed" ||
        req.url ~ "^/my-account/" ||
        req.url ~ "^/cart/" ||
        req.url ~ "^/checkout/" ||
        req.url ~ "/paypal/" ||
        req.url ~ "^/admin/" ||
        req.url ~ "preview=true" ||
        req.url ~ "wc-api") {
        return (pass);
    }

    # --- COOKIES: Bypass para usuarios logados e WooCommerce ---
    if (req.http.cookie ~ "wordpress_logged_in_" ||
        req.http.cookie ~ "comment_author_" ||
        req.http.cookie ~ "woocommerce_cart_hash" ||
        req.http.cookie ~ "woocommerce_items_in_cart" ||
        req.http.cookie ~ "wp_woocommerce_session_") {
        return (pass);
    }

    # --- NORMALIZACAO DE Accept-Encoding ---
    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|jpeg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|swf|flv|webp|avif|woff2)$") {
            unset req.http.Accept-Encoding;
        } else if (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } else if (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    # --- LIMPAR PARAMETROS DE TRACKING DA URL ---
    if (req.url ~ "(\?|&)(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+|_ga|_gl|msclkid|dclid|yclid|ttclid|twclid|li_fat_id)=") {
        set req.url = regsuball(req.url, "(gclid|cx|ie|cof|siteurl|zanpid|origin|fbclid|mc_[a-z]+|utm_[a-z]+|_bta_[a-z]+|_ga|_gl|msclkid|dclid|yclid|ttclid|twclid|li_fat_id)=[-_A-z0-9+()%.]+&?", "");
        set req.url = regsub(req.url, "[?|&]+$", "");
    }

    # --- AUTHORIZATION BEARER = bypass ---
    if (req.http.Authorization ~ "^Bearer") {
        return (pass);
    }

    # --- REMOVER COOKIES para permitir cache ---
    unset req.http.Cookie;

    return (hash);
}

# =============================================================================
# vcl_hash - Chave de cache
# =============================================================================
sub vcl_hash {
    hash_data(req.url);

    if (req.http.host) {
        hash_data(req.http.host);
    } else {
        hash_data(server.ip);
    }

    # Cache separado por device - Newspaper Theme gera HTML diferente
    if (req.http.X-UA-Device) {
        hash_data(req.http.X-UA-Device);
    }

    return (lookup);
}

# =============================================================================
# vcl_backend_fetch - Requisicao para o backend
# =============================================================================
sub vcl_backend_fetch {
    # Informar ao WordPress/plugin que Varnish suporta Cache Tags
    set bereq.http.Surrogate-Capability = "vhp=Surrogate/1.0 tags/1";
}

# =============================================================================
# vcl_backend_response - Resposta do backend
# =============================================================================
sub vcl_backend_response {
    # Grace period: servir conteudo stale por ate 6h se backend cair
    set beresp.grace = 6h;

    # Keep: manter objetos por mais tempo para grace funcionar
    set beresp.keep = 1h;

    # Comprimir respostas de texto
    if (beresp.http.content-type ~ "(text|application/json|application/javascript|application/xml|text/xml|text/css)") {
        set beresp.do_gzip = true;
    }

    # Remover Vary: Cookie do backend (ja limpamos cookies no recv)
    if (beresp.http.Vary ~ "(?i)Cookie") {
        set beresp.http.Vary = regsuball(beresp.http.Vary, "(?i),?\s*Cookie\s*,?", "");
        if (beresp.http.Vary ~ "^\s*$") {
            unset beresp.http.Vary;
        }
    }

    # Nao cachear erros (exceto 404)
    if (beresp.status >= 500) {
        set beresp.uncacheable = true;
        set beresp.ttl = 1s;
        return (deliver);
    }

    # Respostas com Set-Cookie ou Cache-Control: private = nao cachear
    if (beresp.http.Set-Cookie) {
        set beresp.uncacheable = true;
        set beresp.ttl = 0s;
        return (deliver);
    }

    if (beresp.http.Cache-Control ~ "private|no-cache|no-store") {
        set beresp.uncacheable = true;
        set beresp.ttl = 0s;
        return (deliver);
    }

    # Remover Set-Cookie de respostas cacheadas
    if (beresp.ttl > 0s && (bereq.method == "GET" || bereq.method == "HEAD")) {
        unset beresp.http.set-cookie;
    }

    # Se backend nao enviou Cache-Control, nao cachear
    if (!beresp.http.cache-control) {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
        return (deliver);
    }

    # --- TTLs POR TIPO DE CONTEUDO ---

    # Home page - atualiza a cada 5 minutos (site de noticias)
    if (bereq.url == "/") {
        set beresp.ttl = 300s;
    }

    # Paginas de categoria/tag/autor/busca - atualiza a cada 10 minutos
    else if (bereq.url ~ "^/category/" || bereq.url ~ "^/tag/" || bereq.url ~ "^/author/" || bereq.url ~ "^/page/") {
        set beresp.ttl = 600s;
    }

    # Arquivos estaticos servidos pelo backend - 1 dia
    else if (bereq.url ~ "\.(css|js|jpg|jpeg|png|gif|ico|svg|woff|woff2|ttf|eot|webp|avif)$") {
        set beresp.ttl = 86400s;
    }

    # Posts individuais (estrutura: /titulo-da-noticia/) - cache de 1 hora
    # Pega tudo que nao e home, categoria, tag, admin, wp-*, feed, etc.
    else if (bereq.url ~ "^/[a-z0-9]([a-z0-9\-]*)/?\??" && bereq.url !~ "^/wp-" && bereq.url !~ "^/feed" && bereq.url !~ "^/sitemap") {
        set beresp.ttl = 3600s;
    }

    return (deliver);
}

# =============================================================================
# vcl_deliver - Resposta para o cliente
# =============================================================================
sub vcl_deliver {
    # Headers de debug (remover em producao se quiser)
    set resp.http.X-Cache-Age = resp.http.Age;
    unset resp.http.Age;

    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
    set resp.http.X-Cache-Hits = obj.hits;

    # --- CACHE-CONTROL PARA O BROWSER ---
    # WordPress envia no-store por padrao. Substituimos por cache curto
    # para que o browser nao bata no Varnish a cada clique,
    # mas purges ainda funcionem rapido (max 2 min de atraso).
    if (resp.http.Cache-Control !~ "private") {
        unset resp.http.Pragma;
        unset resp.http.Expires;
        set resp.http.Cache-Control = "public, max-age=120, stale-while-revalidate=60";
    }

    # --- REMOVER HEADERS SENSIVEIS ---
    unset resp.http.X-Powered-By;
    unset resp.http.Server;
    unset resp.http.X-Varnish;
    unset resp.http.Via;
    unset resp.http.Link;
    unset resp.http.X-Cache-Tags;
    unset resp.http.Surrogate-Capability;
}

# =============================================================================
# vcl_hit
# =============================================================================
sub vcl_hit {
    # TTL valido - entregar normalmente
    if (obj.ttl >= 0s) {
        return (deliver);
    }
    # TTL expirado: verificar se backend esta vivo
    if (obj.ttl + obj.grace > 0s) {
        if (std.healthy(req.backend_hint)) {
            # Backend saudavel - buscar conteudo novo (purge funciona instantaneo)
            return (miss);
        }
        # Backend doente - servir stale para nao derrubar o site
        set req.http.grace = "stale (backend sick)";
        return (deliver);
    }
    return (miss);
}

# =============================================================================
# vcl_purge
# =============================================================================
sub vcl_purge {
    return (synth(200, "Purged Successfully"));
}
