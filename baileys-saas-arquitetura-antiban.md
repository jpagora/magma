# Arquitetura Anti-Ban para SaaS WhatsApp com Baileys

> **Escopo:** análise de arquitetura de rede e risco operacional para SaaS multi-tenant
> que conecta números de clientes ao WhatsApp via Baileys em VPS compartilhada.

---

## Ressalvas antes de tudo

Três coisas que precisam estar claras antes de qualquer decisão técnica:

1. **A WhatsApp não publica as heurísticas de ban.** Todo peso atribuído a sinais neste
   documento é inferência informada por comportamento observado em produção, não
   documentação oficial. Trate como aproximação, não como especificação.

2. **Baileys é cliente não-oficial e viola os Termos de Serviço da WhatsApp.** Tudo aqui
   é *redução* de risco, não eliminação. Bans vão acontecer independentemente da
   qualidade da infraestrutura.

3. **A única via estruturalmente segura é a Cloud API oficial.** Vale oferecer como tier
   premium para os clientes que puderem pagar.

---

## Parte 1 — Riscos de vários clientes na mesma VPS

Este é o risco dominante, e é maior que qualquer questão de geolocalização.

### Correlação de contas (principal)

Dezenas de números não relacionados saindo do mesmo IP é padrão de *farm*. Quando um
cliente leva denúncia por spam, o IP fica marcado e pode arrastar os demais junto. Você não
controla o comportamento do seu cliente, mas herda a reputação dele.

### Reconexão em massa

Deploy, restart ou OOM faz N sessões reconectarem no mesmo segundo, pelo mesmo IP.
Assinatura clássica de automação.

### Fate-sharing de processo

Cada socket Baileys mantém a sessão inteira em memória; store e histórico crescem com o
tempo. Um crash derruba todos os tenants de uma vez.

### Vazamento entre tenants (LGPD)

Se o `authState` não estiver estritamente isolado por tenant, o `creds.json` de um cliente
pode ficar acessível a outro. Isso é incidente de segurança, não apenas risco de ban.

---

## Parte 2 — VPN com saída compartilhada não resolve

Vale registrar por que a ideia mais intuitiva — colocar a VPS atrás de uma VPN com saída
no Brasil — foi descartada. Vale para qualquer solução desse tipo, gerenciada ou não.

**A saída passa a ser única para a máquina inteira.** Num SaaS multi-tenant isso é o oposto
do que você precisa: reforça exatamente o problema de correlação da Parte 1, em vez de
resolvê-lo.

**Geolocalização é sinal fraco.** Pesa muito menos que comportamento. Usuários viajam, usam
roaming, VPN corporativa. Um número `+55` conectando de fora não é anomalia forte.

**O que pesa é o ASN, não o país.** Um IP de datacenter (Hetzner, Contabo, OVH,
DigitalOcean, AWS) é substancialmente mais suspeito que um residencial ou móvel. Saída num
VPS brasileiro te dá o país mas continua sendo datacenter — você troca "datacenter alemão"
por "datacenter brasileiro". Ganho marginal.

**Cria um ponto único de falha perigoso.** Se o gateway cair, todas as sessões reconectam
simultaneamente pelo IP real da VPS. "N contas mudaram de IP ao mesmo tempo" é um evento
mais anômalo do que nunca ter usado VPN — você piora justamente o cenário que queria
proteger.

**Conclusão:** controle de egress tem que ser **por sessão**, dentro do Baileys, e nunca por
rota global de sistema. É o que as Partes 4 e 5 fazem.

---

## Parte 3 — Por que não dá para usar o IP do próprio usuário

### A ideia

A ferramenta captura o IP, ASN e localização do cliente e "coloca no Baileys" para que a
sessão apareça como vinda da conexão dele.

### Por que é impossível

Não é limitação do Baileys nem regra da WhatsApp. É **TCP**.

O IP de origem de um pacote define *para onde volta a resposta*. Se você forjar o IP do
cliente, o `SYN-ACK` da WhatsApp vai para a máquina dele, não para a sua VPS — o handshake
nunca fecha, o TLS nunca sobe, a sessão nunca existe.

Spoofing de origem só tem utilidade em tráfego unidirecional. Para qualquer conexão
bidirecional, não funciona. E na prática nem sai da VPS: todo provedor sério aplica
filtragem de egress (BCP38).

Também não existe campo no protocolo onde você declare "meu IP real é X". A conexão do
Baileys é WebSocket com Noise por cima — a WhatsApp lê o IP do peer TCP e pronto.
Geolocalização e ASN são **derivados** desse IP, server-side. Não são parâmetros enviados.

### O que o Baileys realmente permite controlar

| Campo | O que é |
|---|---|
| `agent` / `fetchAgent` | IP de saída (via proxy) — o único vetor real |
| `browser` | Rótulo exibido em "Aparelhos conectados" |
| `version` | Versão do WA Web negociada |

Fim da lista. Não existe campo `location`, não existe campo `asn`.

---

## Parte 4 — Pool de proxies por tenant (base da arquitetura)

O IP/ASN capturado do cliente é útil — só não como origem. Use como **critério de
roteamento**: capture no signup, resolva geo + ASN, e escolha do pool o proxy mais próximo.

```js
// no signup, a partir do request do dashboard
const meta = await geoAsn(req.ip)   // { country: 'BR', region: 'SP', asn: 28573 }

// escolhe o exit mais próximo: mesmo ASN > mesmo estado > mesmo país
const proxy = pickProxy(pool, meta)
await db.tenants.update(id, { proxyId: proxy.id })   // sticky, nunca rotacione
```

Com proxy residencial que ofereça targeting por ASN, dá para casar a operadora do cliente
(Vivo, Claro, Algar). É o mais próximo de "parecer com o usuário" que existe de forma
legítima — e continua sendo *seu* IP, apenas escolhido para ser coerente.

### Configuração no Baileys

```js
import { SocksProxyAgent } from 'socks-proxy-agent'

const agent = new SocksProxyAgent(tenant.proxyUrl)

const sock = makeWASocket({
  auth: state,
  agent,                    // WebSocket
  fetchAgent: agent,        // upload/download de mídia
  browser: tenant.browser,  // FIXO por tenant, nunca randomize
})
```

> Confira a assinatura contra a sua versão do Baileys — mudou entre majors.

### Regras de ouro do pool

- **Sticky IP por tenant, persistido em banco.** Estabilidade do IP para uma mesma sessão
  importa mais que o país do IP. Trocar de IP a cada reconexão é pior que ficar num
  datacenter estrangeiro fixo.
- **IPv6 é barato.** Muitos provedores entregam um `/64` — dá um IPv6 distinto por tenant
  sem custo adicional. Teste conectividade antes; nem sempre funciona bem.
- **Teto de sessões por IP** (~10 a 20) e não misture tenants de perfis de risco muito
  diferentes no mesmo IP.

Esta é a camada padrão: resolve correlação sem exigir nada do cliente. As opções da Parte 5
são para os tenants de maior valor ou maior risco.

---

## Parte 5 — Arquiteturas que entregam o IP real do cliente

Se o objetivo é a sessão sair pelo IP real do cliente, pare de simular e use o IP real.
Duas formas, nenhuma delas dependendo de VPN gerenciada de terceiro.

### Opção A — Agente local no cliente

Um binário ou container leve que o cliente roda na máquina dele. Ele segura a sessão
Baileys e conecta na WhatsApp pela conexão dele; seu backend fala com o agente por
WebSocket persistente (o agente disca para você, então funciona atrás de NAT sem
configuração).

IP, ASN e fingerprint residencial autênticos — porque são reais.

**Custo:** fricção de instalação, máquina precisa ficar ligada, suporte e auto-update.

### Opção B — WireGuard próprio, saída na rede do cliente

Mesma ideia, sem exigir que o cliente rode a stack do Baileys. Um container por tenant na
sua VPS, cada um com sua interface WireGuard, e o egress daquele container saindo pela
conexão do cliente.

**Na sua VPS**, dentro do container do tenant:

```ini
[Interface]
PrivateKey = <chave-do-container>
Address    = 10.90.0.2/32

[Peer]
PublicKey  = <chave-publica-do-cliente>
AllowedIPs = 0.0.0.0/0        # todo o egress do container vai pelo túnel
```

**Na caixa do cliente** (mini-PC, Raspberry Pi, roteador com OpenWRT):

```ini
[Interface]
PrivateKey = <chave-do-cliente>
Address    = 10.90.0.1/24
ListenPort = 51820

[Peer]
PublicKey           = <chave-publica-do-container>
AllowedIPs          = 10.90.0.2/32
Endpoint            = vps.seudominio.com:51820
PersistentKeepalive = 25
```

E, na caixa do cliente, encaminhamento com NAT:

```bash
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -A POSTROUTING -o <interface-wan> -j MASQUERADE
```

> Ajuste `<interface-wan>` e as faixas de IP à realidade da rede. Estes trechos são
> ilustrativos e não foram executados — valide num tenant piloto antes de escalar.

**Detalhes que importam:**

- **Quem disca é o cliente.** Residencial fica atrás de NAT, então a caixa do cliente
  inicia a conexão e mantém `PersistentKeepalive = 25`. Se o IP dele mudar (IP dinâmico),
  o túnel se restabelece sozinho.
- **Sem rota global.** Como cada container tem seu próprio namespace de rede, o
  `AllowedIPs = 0.0.0.0/0` afeta apenas aquele tenant. O host não é tocado.
- **Gestão de chaves é sua.** Sem serviço de coordenação, você gera e distribui o par de
  chaves por tenant. Vale entregar um script ou imagem pronta para o cliente — instalação
  manual de WireGuard vira ticket de suporte.
- **Monitore o túnel.** Se cair, a sessão daquele tenant deve **pausar**, não cair para o
  IP da VPS. Sem isso você recria o problema da Parte 2 em escala menor.

**Custo:** o cliente mantém uma caixa ligada; você assume gestão de chaves e monitoramento
de túnel. Menos fricção que a Opção A, e você mantém toda a orquestração.

### O ganho real destas duas opções

Não é casar geolocalização — isso continua sendo sinal fraco. O que faz A e B valerem o
esforço é **eliminar a correlação**: cada sessão sai de um IP não relacionado às outras.
O problema de um cliente spammer queimar o IP de todos os demais simplesmente deixa de
existir, porque não há IP compartilhado.

Coerência geográfica é bônus.

---

## Parte 6 — Reconexão

Backoff exponencial **com jitter aleatório**, espalhando reconexões numa janela de 30 a 180
segundos. Nunca todos de uma vez. Isso sozinho remove uma das assinaturas mais óbvias de
automação.

Persista o auth state corretamente: re-pareamento frequente é sinal forte. A sessão deve
sobreviver a deploy.

Mantenha `browser` fixo por tenant. Randomizar a cada reconexão parece pior, não melhor.

---

## Parte 7 — Camada comportamental

Infraestrutura reduz correlação. **Comportamento é o que efetivamente dispara o ban.**
Por número:

- **Warm-up de números novos.** Começar em 20 a 50 mensagens/dia e escalar ao longo de
  semanas. Número novo disparando volume é o caminho mais rápido para o ban.
- **Delay aleatório** entre envios (segundos, não milissegundos), com
  `sendPresenceUpdate('composing')` e read receipts.
- **Nunca texto idêntico em massa.** Templates com variação real.
- **Priorize conversas iniciadas pelo contato.** Cold outreach para número que nunca falou
  com você é o maior gerador de denúncia.
- **Opt-in de verdade**, exigido contratualmente dos seus clientes.

---

## Parte 8 — Detecção e kill switch

Instrumente e corte automaticamente. Métricas por tenant:

- taxa de falha de entrega
- razão de envios para números desconhecidos
- pico súbito de volume
- `DisconnectReason.loggedOut` / `badSession` em sequência

Tenant que ultrapassa os limiares entra em pausa automática. Sem isso, um cliente abusivo
queima o IP de todos os outros antes de você perceber.

---

## Parte 9 — Isolamento

Um processo ou container por tenant (ou por grupo pequeno). Auth state em volume isolado,
criptografado em repouso.

Crash de um não derruba os demais, e você consegue reciclar o IP de um tenant sem tocar nos
outros.

---

## Parte 10 — LGPD

IP, ASN e geolocalização do cliente são **dado pessoal**. Se você captura e armazena para
roteamento, isso precisa constar na política de privacidade com a finalidade declarada.

É uma linha de texto, mas tem que estar lá.

---

## Parte 11 — Continuidade operacional

Bans vão acontecer. Trate isso como requisito de produto, não como exceção:

- **Histórico de mensagens no seu banco**, nunca dependendo da sessão.
- **Re-pareamento em poucos cliques.**
- **Expectativa alinhada em contrato.** O cliente que perde o número e descobre que perdeu
  o histórico junto vira processo.

---

## Resumo de prioridades

| Ação | Impacto | Esforço |
|---|---|---|
| VPN com saída compartilhada para a VPS | Marginal, adiciona SPOF | Baixo — **não recomendado** |
| 1 IP/proxy por tenant (sticky, ASN-aware) | **Alto** | Médio |
| Jitter na reconexão | Alto | Baixo |
| Rate limit + warm-up por número | **Alto** | Médio |
| Kill switch por tenant | Alto | Médio |
| Isolamento por processo/container | Médio-alto | Médio |
| WireGuard com saída no cliente (Opção B) | Muito alto | Médio-alto |
| Agente local no cliente (Opção A) | Muito alto | Alto |
| Cloud API oficial (tier premium) | Elimina o problema | Alto |

### Ordem sugerida de implementação

1. Isolamento por container + jitter na reconexão — barato, resolve o pior dos sintomas.
2. Pool de proxies sticky por tenant — resolve correlação para toda a base.
3. Rate limit, warm-up e kill switch — é aqui que os bans realmente param.
4. WireGuard com saída no cliente para os tenants de maior valor ou maior risco.
5. Cloud API oficial como tier premium.

**Regra de bolso:** rede resolve correlação; comportamento resolve denúncia. Você precisa
das duas camadas — nenhuma substitui a outra.
