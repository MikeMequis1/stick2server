[English](README.md) | **Português (Brasil)**

# Stick2Server — servidor de sincronização do Stick2Planner

Serviço pequeno em Dart/shelf, sem Flutter. Armazena blobs opacos por entidade,
com revisão por item, idempotência por `changeId` e cursor global de mudanças.

O fluxo de conexão/pareamento/sync do app fica no
[repositório do Stick2Planner](https://github.com/MikeMequis1/Stick2Planner).

## Compatibilidade

- O servidor **0.2.1** tem como alvo o Stick2Planner **0.3.0** e continua
  aceitando clientes anteriores.
- As entidades de sync são `postIt`, `note`, `history` e `tag`. Os payloads são
  armazenados de forma opaca; cores de tag, paletas e regras de conclusão são
  interpretadas pelo app, então campos novos do app não exigem atualizar o
  servidor.
- Payloads de post-it podem carregar `timeMinutes` e `tagIds`; definições de tag
  viajam pela entidade `tag`.

## Início rápido com a imagem latest

```bash
cp .env.example .env
# edite ADMIN_TOKEN e PUBLIC_URL

docker compose pull
docker compose up -d
curl -fsS http://127.0.0.1:8090/v1/health
```

O Compose baixa `ghcr.io/mikemequis1/stick2server:latest` e sempre consulta o
registry ao iniciar. Use `STICK2SERVER_IMAGE` para sobrescrever a imagem.

## Tags da imagem

- `latest` — branch `main` atual.
- `X.Y.Z` e `X.Y` — tags de release.
- `sha-<commit>` — imagem imutável do commit.

As imagens são publicadas no GitHub Container Registry para `linux/amd64` e
`linux/arm64`.

## Endpoints

| Método | Rota | Auth | Uso |
| --- | --- | --- | --- |
| GET | `/v1/health` | — | saúde/versão/serverId |
| POST | `/v1/sync` | token do dispositivo | push + pull em uma chamada |
| GET | `/v1/sync/stats` | token do dispositivo | contagens de dados ativos |
| GET | `/v1/sync/snapshot` | token do dispositivo | snapshot completo (manter remoto) |
| POST | `/v1/sync/replace` | token do dispositivo | substitui conjunto (manter local) |
| POST | `/v1/pair` | token de pareamento | troca por token do dispositivo |
| POST | `/v1/admin/pairing-tokens` | token admin | cria token de pareamento (TTL) |
| GET | `/v1/admin/devices` | token admin | lista dispositivos |
| POST | `/v1/admin/devices/<id>/revoke` | token admin | revoga dispositivo |

Push aplica apenas com `baseRev` igual à revisão atual; divergência devolve
`conflicts` com a versão do servidor. Reenvio do mesmo `changeId` devolve o ack
anterior. Pull retorna mudanças após `since` com o estado atual da entidade.

`/v1/sync/stats` e `/v1/sync/snapshot` alimentam a conferência local × remota do
app. `/v1/sync/replace` substitui o conjunto remoto pelo snapshot local: o que
não existir no envio vira tombstone e o histórico é preservado como auditoria.

## Variáveis

| Variável | Padrão | Descrição |
| --- | --- | --- |
| `PORT` | `8090` | porta HTTP |
| `DB_PATH` | `data/planner-server.sqlite` | arquivo SQLite |
| `ADMIN_TOKEN` | — | obrigatório para servir/parear |
| `PUBLIC_URL` | — | URL exibida no pareamento |

### Gerar o ADMIN_TOKEN

O servidor lê `ADMIN_TOKEN` do ambiente; ele não é criado automaticamente ao
subir o container. Gere um valor forte e grave no `.env` antes de iniciar:

```bash
# Neste repositório
dart run bin/server token
# ou: openssl rand -hex 32
```

Copie a saída para `ADMIN_TOKEN=` no `.env` e recrie o serviço:

```bash
docker compose up -d --force-recreate
```

Para consultar o valor atual (no host, com acesso ao `.env`):

```bash
grep '^ADMIN_TOKEN=' .env
```

Esse token é a senha administrativa da página web e dos endpoints
`/v1/admin/*`; o app pareado usa tokens de dispositivo separados.

## Docker Compose

Imagem pronta (recomendado):

```bash
cp .env.example .env
# edite ADMIN_TOKEN e PUBLIC_URL
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://127.0.0.1:8090/v1/health
```

Build local:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

O volume nomeado `stick2server-data` guarda o SQLite. Backup:

```bash
docker run --rm -v stick2server-data:/data -v "$PWD/backups:/backup" \
  debian:bookworm-slim sh -c 'apt-get update -qq && apt-get install -y -qq sqlite3 >/dev/null && sqlite3 /data/planner-server.sqlite ".backup /backup/planner-$(date +%F).sqlite"'
```

## Migrando uma instalação existente

Uma instalação antiga pode usar o volume `stick2planner_planner-data`. Para
preservar o SQLite:

```bash
# no diretório da instalação antiga, pare a stack
docker compose down
# ou: docker stop stick2planner-api

docker volume create stick2server-data
docker run --rm \
  -v stick2planner_planner-data:/from \
  -v stick2server-data:/to \
  alpine sh -c 'cp -a /from/. /to/'

docker compose up -d
```

## Pareamento

```bash
docker compose exec api /app/bin/server pair 300
```

Saída (uma vez, com TTL):

```json
{
  "url": "http://192.168.0.10:8090",
  "serverId": "…",
  "pairingToken": "…",
  "expiresAt": "2026-11-04T…Z"
}
```

Esse JSON é o conteúdo do QR de pareamento. O app troca o token em `/v1/pair`
e recebe um token individual, guardado apenas no armazenamento seguro.

## Dispositivos

```bash
docker compose exec api /app/bin/server devices
docker compose exec api /app/bin/server revoke <deviceId>
```

## Testes

```bash
dart pub get
dart analyze
dart test
```

## Página web de pareamento

Abra `https://planner.<tailnet>.ts.net/` (ou o endereço usado para o serviço) no
navegador e informe o `ADMIN_TOKEN` para entrar. A página mostra:

- QR Code de pareamento **renovado automaticamente** enquanto estiver aberta
  (TTL de 5 min, renovação em 4,5 min);
- código textual equivalente para colar no app;
- dispositivos pareados, último acesso e botões de **renomear** e revogar;
- alternância **Português/English** no cliente, sem recarregar; a escolha fica
  em `localStorage` e também traduz contagem do QR, estados e ações;
- botão de sair (sessão em memória, cookie `HttpOnly`/`SameSite=Strict`).

O CLI continua disponível para automação:

```bash
docker compose exec api /app/bin/server pair 300
```

A página e as APIs `/api/pairing`, `/api/devices` exigem sessão administrativa;
sem cookie, retornam a tela de login/401. Não exponha a página fora da
LAN/Tailnet.

## Exposição opcional

O serviço pode ficar na LAN ou ser exposto por VPN/Tailscale ou proxy reverso
com TLS. Nesse caso:

- use `PUBLIC_URL` com a URL externa para que o QR de pareamento carregue o
  endereço correto;
- encaminhe o proxy para a porta `8090`;
- mantenha autenticação/TLS no proxy e não publique a porta diretamente na
  internet;
- configure labels/regras do proxy no ambiente de deploy, fora deste repositório.

## Segurança

- Tokens são guardados como SHA-256; comparação em tempo constante.
- Tokens de pareamento são de uso único e expiram.
- Corpo limitado a 8 MB, payload a 1 MB e lote a 500 mudanças.
- Sem logs de token ou payload.
- Exposição esperada: LAN ou Tailscale, porta 8090; sem publicar na internet.
- `data/` e `.env` são ignorados pelo git.
