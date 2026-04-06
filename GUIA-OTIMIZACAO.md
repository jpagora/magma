# Guia de Otimizacao - jpagora.com

## Servidor: 24GB RAM / 8 vCPUs
## Stack: CloudPanel + PHP 8.4 + Nginx + Varnish + Redis + MariaDB + WP Rocket

---

## O QUE FOI ALTERADO E POR QUE

---

### 1. NGINX (nginx-vhost-otimizado.conf)

| Item | Antes | Depois | Motivo |
|------|-------|--------|--------|
| Timeouts wp-admin | 600s | 120s | 600s e excessivo - travava workers desnecessariamente |
| Timeouts frontend proxy | 60s | 30s connect, 60s read/send | Connect nao precisa de 60s pro localhost |
| FastCGI timeouts | 600s | 300s | 5min e mais que suficiente para qualquer operacao WP |
| FastCGI buffers | 4x256k | 8x256k + busy 512k | Respostas grandes do Newspaper Theme precisam mais buffers |
| open_file_cache | max=5000, min_uses=2 | max=8000, min_uses=1 | Com 24GB pode cachear mais descritores |
| open_file_cache_errors | off | on | Cachear 404 de estaticos evita I/O repetido |
| Seguranca | Basica | Adicionado wp-config, .env, .ht*, .sql, .bak | Protegia apenas .git e xmlrpc |
| Headers seguranca | Ausentes | X-Content-Type, X-Frame, Referrer-Policy | Boas praticas e SEO |
| Device hash no Varnish | Ativo | Removido (comentado) | Newspaper Theme e responsivo - duplicava cache sem necessidade |

**ATENCAO:** O bloco `~/\.git` no seu original usa `~` (case-sensitive). Mantive assim, mas confirme que funciona.

---

### 2. PHP 8.4 (php-additional-directives-otimizado.ini)

| Item | Antes | Depois | Motivo |
|------|-------|--------|--------|
| `opcache.enable_cli` | 1 | 0 | CLI nao roda no servidor web - desperdicava memoria compartilhada |
| `opcache.max_wasted_percentage` | 5 | 10 | Com 512MB de opcache, 5% e muito conservador - causava restarts frequentes |
| `opcache.huge_code_pages` | Ausente | 1 | Reduz TLB misses - ganho real de 2-5% em CPU |
| `realpath_cache_size` | 128M | 8M | 128M e ABSURDO - WordPress usa ~500KB. Desperdicava 127.5MB de RAM |
| `memory_limit` | Ausente | 512M | Garantir que plugins pesados do Newspaper nao estouram |
| `max_execution_time` | Ausente | 300s | Limite seguro |
| `max_input_vars` | Ausente | 5000 | Newspaper Theme precisa pra customizer |
| `upload_max_filesize` | Ausente | 64M | Para upload de imagens |
| Sessao segura | Basica | httponly + secure + strict_mode | Seguranca de cookies |
| Ponto-e-virgula nos valores | Presente (`;`) | Removido | Os `;` no final dos valores podem causar problemas |

**CRITICO:** Seus valores tinham `;` no final (ex: `display_errors=off;`). Em PHP INI, o `;` inicia um comentario. Dependendo de como o CloudPanel processa, pode estar ignorando o valor. Remova todos os `;` do final.

---

### 3. VARNISH (varnish-otimizado.vcl)

| Item | Antes | Depois | Motivo |
|------|-------|--------|--------|
| Health check (probe) | Ausente | Adicionado | Varnish precisa saber se o backend esta vivo para grace funcionar |
| `connect_timeout` | Ausente (default 3.5s) | 5s | Explicito e seguro |
| `between_bytes_timeout` | Ausente | 5s | Evita conexoes penduradas |
| `beresp.grace` | 3d | 6h | 3 dias e muito - conteudo ficaria muito desatualizado |
| `beresp.keep` | Ausente | 1h | Permite grace funcionar mesmo apos TTL expirar |
| Grace no vcl_hit | Entregava sempre | Verifica ttl + grace corretamente | Antes podia servir conteudo infinitamente velho |
| ESI | Ativo em todo `text` | Removido | Newspaper/WP Rocket nao usam ESI - adiciona overhead de parsing |
| TTL categorias/tags | Ausente | 600s (10min) | Paginas de listagem atualizam com frequencia moderada |
| TTL posts | Ausente | 3600s (1h) | Posts ja publicados mudam pouco |
| Tracking params | Basico | +_ga, _gl, msclkid, dclid, yclid, ttclid, twclid, li_fat_id | Mais parametros de analytics fragmentavam o cache |
| BAN method | Ausente | Adicionado | Permite WP Rocket fazer limpeza em massa |
| Bypass /feed | Ausente | Adicionado | Feeds RSS devem ser sempre frescos |
| Bypass /wp-json | Ausente | Adicionado | API REST nao deve ser cacheada |
| Bypass WooCommerce cookies | Ausente | Adicionado (preventivo) | Se um dia usar WooCommerce, ja esta protegido |
| `vcl_deliver` Cache-Control | Sobrescrevia com no-store | Removido | **BUG CRITICO**: voce estava mandando `no-store` pro browser em TODAS as respostas publicas! Isso anulava o cache do navegador |
| Device hash | Mobile/Desktop separado | Removido | HTML responsivo = mesmo conteudo. Dobrava o cache sem necessidade |

**BUG CRITICO ENCONTRADO:** No seu `vcl_deliver` original, havia este bloco:
```
if (resp.http.Cache-Control !~ "private") {
    set resp.http.Pragma = "no-cache";
    set resp.http.Expires = "-1";
    set resp.http.Cache-Control = "no-store, no-cache, must-revalidate, max-age=0";
}
```
Isso mandava o **browser NUNCA cachear nada**. Toda pagina publica recebia `no-store`. O browser buscava tudo de novo a cada visita, mesmo com Varnish respondendo rapido. Isso aumentava drasticamente o consumo de banda e o tempo de carregamento para visitantes que voltam.

---

### 4. MariaDB (mariadb-otimizado.cnf) - BONUS

| Item | Valor | Motivo |
|------|-------|--------|
| `innodb_buffer_pool_size` | 8G | ~33% da RAM total. Principal cache do banco |
| `innodb_buffer_pool_instances` | 4 | Reduz contencao de lock com multiplas threads |
| `innodb_log_file_size` | 1G | Logs maiores = menos I/O de flush |
| `innodb_flush_log_at_trx_commit` | 2 | Flush a cada segundo (nao a cada transacao). Seguro para blog |
| `query_cache` | OFF | Redis + WP Rocket ja cacheiam. Query cache causa lock contention |
| `thread_handling` | pool-of-threads | Melhor que thread-per-connection para muitas conexoes curtas |
| `slow_query_log` | ON (>2s) | Identificar queries lentas do WordPress/plugins |

---

### 5. REDIS - Configuracao no WordPress

No `wp-config.php`, adicione (se ainda nao tem):
```php
// Redis Object Cache
define('WP_REDIS_HOST', '127.0.0.1');
define('WP_REDIS_PORT', 6379);
define('WP_REDIS_DATABASE', 0);
define('WP_REDIS_TIMEOUT', 1);
define('WP_REDIS_READ_TIMEOUT', 1);
define('WP_REDIS_MAXTTL', 86400);

// Prefixo unico (importante se tiver mais de um site)
define('WP_REDIS_PREFIX', 'jpagora_');

// Desabilitar cache de grupos transientes (WP Rocket ja cuida)
define('WP_REDIS_DISABLED_GROUPS', ['counts', 'plugins', 'themes']);
```

Plugin recomendado: **Redis Object Cache** (Till Kruss) ou **Object Cache Pro** (se quiser pago).

---

### 6. WP ROCKET - Configuracoes Recomendadas

- **Page Cache**: ON (mas Varnish e o cache principal)
- **Cache para dispositivos moveis**: OFF (tema responsivo)
- **Separate cache for logged-in users**: OFF (Varnish ja faz bypass)
- **Minificacao CSS/JS**: ON
- **Combinar CSS/JS**: TESTAR (pode quebrar com Newspaper)
- **Remove Unused CSS**: ON (grande ganho no Newspaper que carrega muito CSS)
- **Delay JS Execution**: ON (cuidado com ads - testar)
- **Prefetch DNS**: Adicione dominios de ads, analytics, fonts
- **Preload**: ON com sitemap do SEOPress
- **CDN**: Considere Cloudflare ou BunnyCDN para estaticos
- **Heartbeat**: Reduzir para 120s no admin, desabilitar no frontend
- **Varnish**: Ativar integracao com Varnish no WP Rocket (Settings > CDN > Varnish)

---

## ORDEM DE APLICACAO

1. **BACKUP** - Faca backup de tudo antes
2. **PHP INI** - Aplique e reinicie PHP-FPM (`systemctl restart php8.4-fpm`)
3. **MariaDB** - Aplique e reinicie (`systemctl restart mariadb`)
4. **Varnish VCL** - Aplique e reinicie (`systemctl restart varnish`)
5. **Nginx vhost** - Aplique e teste (`nginx -t && systemctl reload nginx`)
6. **Redis** - Configure wp-config.php e ative o plugin
7. **WP Rocket** - Ajuste as configuracoes e limpe todo o cache
8. **TESTE** - Verifique se tudo funciona, monitore logs por 24h

---

## COMO VERIFICAR SE ESTA FUNCIONANDO

```bash
# Verificar se Varnish esta cacheando (deve retornar X-Cache: HIT na segunda vez)
curl -I https://jpagora.com
curl -I https://jpagora.com

# Verificar OPcache
php -r "print_r(opcache_get_status());"

# Verificar Redis
redis-cli ping
redis-cli info stats | grep hits

# Verificar MariaDB
mysqladmin status
mysql -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';"

# Monitorar slow queries
tail -f /var/log/mysql/slow.log
```
