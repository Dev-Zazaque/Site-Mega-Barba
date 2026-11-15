<div align="center">

<img src="fotos/logo.png" alt="Mega Barba — Barbearia Tradicional" width="160" />

# Mega Barba

**Sistema de agendamento online para barbearia, com painel interno, programa de fidelidade e app instalável (PWA).**

[![HTML5](https://img.shields.io/badge/HTML5-E34F26?style=for-the-badge&logo=html5&logoColor=white)](#stack-tecnológica)
[![Tailwind CSS](https://img.shields.io/badge/Tailwind_CSS-06B6D4?style=for-the-badge&logo=tailwindcss&logoColor=white)](#stack-tecnológica)
[![JavaScript](https://img.shields.io/badge/JavaScript-F7DF1E?style=for-the-badge&logo=javascript&logoColor=black)](#stack-tecnológica)
[![Supabase](https://img.shields.io/badge/Supabase-3ECF8E?style=for-the-badge&logo=supabase&logoColor=white)](#banco-de-dados)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=for-the-badge&logo=postgresql&logoColor=white)](#banco-de-dados)
[![PWA](https://img.shields.io/badge/PWA-instalável-5A0FC8?style=for-the-badge&logo=pwa&logoColor=white)](#pwa-e-modo-offline)

[Visão geral](#visão-geral) · [Funcionalidades](#funcionalidades) · [Arquitetura](#arquitetura) · [Banco de dados](#banco-de-dados) · [Segurança](#segurança) · [Instalação](#instalação-e-configuração) · [Roadmap](#roadmap)

</div>

---

## Visão geral

O **Mega Barba** substitui a agenda de papel e as conversas soltas no WhatsApp por um fluxo de agendamento simples para o cliente e uma visão de caixa e agenda em tempo real para a equipe.

O sistema é composto por duas aplicações web que compartilham o mesmo banco de dados e o mesmo *design system*:

| Aplicação | Arquivo | Público | Objetivo |
|---|---|---|---|
| **Site / Agendamento** | `index.html` | Clientes | Landing page e reserva de horário em 4 passos |
| **Painel interno** | `painel.html` | Barbeiros e dono | Agenda do dia, caixa, bloqueios e folgas |

Não há servidor próprio: o front-end é estático e toda a regra de negócio e persistência rodam no **PostgreSQL do Supabase**, através de funções SQL.

---

## Funcionalidades

### Para o cliente

- **Agendamento em 4 passos:** serviço → barbeiro → dia e horário → dados, com barra de progresso.
- **Disponibilidade real:** os horários ocupados, os intervalos de almoço e as folgas vêm do servidor a cada consulta. Não existe "horário fantasma".
- **Duração por serviço:** cada serviço ocupa o tempo que realmente leva (30 ou 60 min), e a grade respeita isso.
- **Meus agendamentos:** consulta, **remarcação** e **cancelamento** usando apenas o número de WhatsApp.
- **Cartão fidelidade:** a cada 10 serviços concluídos e pagos, o próximo é gratuito. O progresso aparece no momento do agendamento.
- **Dados lembrados:** nome e WhatsApp ficam salvos no aparelho para os próximos agendamentos.
- **App instalável:** botão "Instalar o app no celular" quando o navegador permite.

### Para a equipe (painel interno)

- **Login por PIN**, validado no servidor, com dois perfis: `BARBEIRO` e `DONO`.
- **Caixa do dia:** valor realizado, valor a receber, quantidade de atendimentos e próximo cliente.
- **Agenda ao vivo:** atualização automática a cada 30 segundos enquanto a aba está visível.
- **Ações por atendimento:** concluir (alimenta o caixa e a fidelidade) ou cancelar.
- **Bloqueio de horários** para pausas e imprevistos.
- **Folga / feriado:** marca o dia inteiro como indisponível e impede a folga se houver clientes confirmados.
- **Turno e almoço configuráveis** por barbeiro.
- **Visão do dono:** enxerga a agenda de toda a equipe e filtra por barbeiro, sem poder alterar turnos nem bloquear horários de outra pessoa.

### Identidade visual

- Linguagem **liquid glass** (vidro fosco com brilho que acompanha o cursor), paleta grafite, vermelho e azul inspirada no poste de barbeiro.
- Emblema da marca em **SVG com texto em arco**, definido uma única vez e reutilizado via `<use>`.
- Título animado letra a letra, frase de destaque palavra a palavra, faixa de poste giratória e fundo com zoom lento.
- Entrada escalonada das telas e `prefers-reduced-motion` respeitado.

---

## Arquitetura

```text
┌──────────────────────────┐        ┌──────────────────────────┐
│  index.html              │        │  painel.html             │
│  Cliente · agendamento   │        │  Equipe · agenda e caixa │
└────────────┬─────────────┘        └────────────┬─────────────┘
             │       tema.css (design system)    │
             │                                   │
             └──────────────┬────────────────────┘
                            │  supabase-js  →  db.rpc("função", { … })
                            ▼
             ┌─────────────────────────────────────┐
             │   Supabase · PostgreSQL              │
             │                                      │
             │   RLS ativo, sem acesso direto às    │
             │   tabelas. Toda leitura e escrita    │
             │   passa por funções SECURITY DEFINER │
             └─────────────────────────────────────┘

   sw.js + manifest*.json  →  PWA: instalação e cache do "esqueleto"
```

### Decisões técnicas

- **Sem framework e sem *build*:** HTML + JavaScript nativo + Tailwind via CDN. Deploy em qualquer hospedagem estática.
- **Backend como funções SQL:** o front só chama `rpc()`. Regras como horário de funcionamento, fidelidade e validações vivem no banco e não podem ser burladas pelo navegador.
- **Consistência garantida pelo banco:** conflitos de horário são impedidos por uma *exclusion constraint* (veja abaixo), e não por checagem no JavaScript.
- **Script SQL idempotente:** pode ser executado várias vezes sem apagar dados.
- **Fuso horário fixo:** validações de data usam `America/Sao_Paulo`, independentemente do fuso do aparelho.

---

## Banco de dados

Todo o esquema está em [`supabase.sql`](supabase.sql).

### Tabelas

| Tabela | Descrição |
|---|---|
| `barbeiros` | Equipe, papel (`BARBEIRO` / `DONO`), PIN em hash, turno e almoço |
| `servicos` | Catálogo com preço, descrição, ordem e **duração em minutos** |
| `agendamentos` | Reservas, bloqueios e atendimentos concluídos, com flag `brinde` |
| `folgas` | Dias inteiros indisponíveis por barbeiro |

### Prevenção de agendamento duplo

Em vez de depender de verificações no front-end, o banco rejeita sobreposição de horários do mesmo barbeiro no mesmo dia:

```sql
alter table agendamentos add constraint sem_choque
  exclude using gist (
    barbeiro_id with =,
    data with =,
    int4range(inicio, inicio + duracao) with &&
  );
```

A coluna `inicio` é uma coluna gerada (minutos desde 00:00), então um serviço de 60 min bloqueia corretamente dois intervalos de 30 min. Em caso de disputa pelo mesmo horário, a função devolve o erro `HORARIO_OCUPADO`, tratado na interface.

### Funções expostas

| Contexto | Funções |
|---|---|
| **Cliente** | `listar_barbeiros`, `ocupacao`, `criar_agendamento`, `meus_agendamentos`, `remarcar_meu`, `cancelar_meu`, `fidelidade` |
| **Painel** | `painel_login`, `painel_agenda`, `painel_concluir`, `painel_cancelar`, `painel_bloquear`, `painel_salvar_turno`, `painel_folga`, `painel_folga_dia` |

### Regras de negócio no servidor

- Atendimento de **terça a sábado, das 09h às 19h**. Domingo e segunda são rejeitados mesmo que alguém chame a função diretamente.
- **Fidelidade:** a cada 10 serviços `CONCLUIDO` e pagos no mesmo WhatsApp, o próximo agendamento é criado com valor `0` e `brinde = true`.
- Validação de nome, WhatsApp (10 a 11 dígitos), data não retroativa e existência de serviço e barbeiro.
- Cliente só consegue alterar ou cancelar agendamentos do **próprio WhatsApp** e com status `CONFIRMADO`.

---

## Segurança

| Camada | Medida |
|---|---|
| **Acesso a dados** | RLS habilitado nas quatro tabelas. Apenas `servicos` tem leitura pública. O resto só é acessível por funções `SECURITY DEFINER` com `search_path` fixo. |
| **Autenticação do painel** | PIN conferido no servidor com `crypt()` (bcrypt) contra `pin_hash`. A função `auth_pin` tem `EXECUTE` revogado de `anon` e `authenticated`. |
| **Autorização** | Cada função do painel valida o papel: barbeiro só altera os próprios dados, e o dono tem leitura global. |
| **Chave do front-end** | Apenas a chave pública (*anon / publishable*) do Supabase é usada. Ela é segura no navegador porque o RLS bloqueia o acesso direto. **Nunca use a `service_role` no front-end.** |
| **XSS** | Dados dinâmicos são escapados antes de entrar no HTML do painel. |
| **Service Worker** | Nunca armazena respostas do Supabase: agenda e horários vêm sempre da rede. |

> ⚠️ **Antes de publicar:** o `supabase.sql` cria usuários de exemplo com PINs padrão. **Troque todos os PINs** (veja [Primeiro acesso](#primeiro-acesso)) e nunca versione arquivos com credenciais.

---

## PWA e modo offline

- `manifest.json` e `manifest-painel.json`: dois apps instaláveis independentes (cliente e painel), com ícones 192 px e 512 px *maskable*.
- `sw.js`:
  - páginas: **rede primeiro**, com *fallback* para o cache quando offline;
  - arquivos estáticos: **cache primeiro** com atualização em segundo plano;
  - domínios do Supabase: **sempre rede**.
- Para forçar a atualização nos aparelhos após um deploy, altere a constante `VERSAO` em `sw.js`.

---

## Stack tecnológica

| Camada | Tecnologia |
|---|---|
| Interface | HTML5, [Tailwind CSS](https://tailwindcss.com/) (CDN), CSS próprio (`tema.css`) |
| Lógica | JavaScript (ES2020+), sem *build* |
| Backend / BaaS | [Supabase](https://supabase.com/) (PostgreSQL, RLS, funções SQL) |
| Cliente de dados | `@supabase/supabase-js` 2.45.4 |
| Extensões PostgreSQL | `pgcrypto`, `btree_gist` |
| Tipografia | Plus Jakarta Sans, Playfair Display, Oswald |
| App | Web App Manifest + Service Worker |

---

## Estrutura do repositório

```text
.
├── index.html               # Site do cliente e fluxo de agendamento
├── painel.html              # Painel interno (barbeiros e dono)
├── tema.css                 # Design system compartilhado
├── sw.js                    # Service Worker
├── manifest.json            # PWA do cliente
├── manifest-painel.json     # PWA do painel
├── supabase.sql             # Esquema, funções e dados iniciais
├── fotos/
│   ├── logo.png
│   ├── logo.svg
│   ├── fundo.jpg
│   ├── ferramentas.jpg
│   ├── wallace.webp
│   └── alexsandro.webp
└── icons/
    ├── icon-180.png
    ├── icon-192.png
    └── icon-512.png
```

> As páginas buscam imagens em `fotos/` e ícones em `icons/`. Mantenha essa organização de pastas.

---

## Instalação e configuração

### 1. Banco de dados

1. Crie um projeto gratuito em [supabase.com](https://supabase.com/).
2. Abra **SQL Editor**, cole o conteúdo de `supabase.sql` e clique em **Run**.

### 2. Conectar o front-end

No início do `<script>` de **`index.html`** e de **`painel.html`**, informe a URL e a chave **pública** do projeto (*Project Settings → API*):

```js
const SUPABASE_URL = "https://<seu-projeto>.supabase.co";
const SUPABASE_KEY = "<sua-chave-publica-anon-ou-publishable>";
```

### 3. Rodar localmente

```bash
npx serve .
# ou
python3 -m http.server 8080
```

Acesse `http://localhost:8080` (cliente) e `http://localhost:8080/painel.html` (equipe). Use sempre um servidor local, porque o Service Worker não funciona via `file://`.

### Primeiro acesso

O script cria dois barbeiros e um perfil de dono com **PINs de exemplo**. Defina PINs próprios no SQL Editor:

```sql
update barbeiros
   set pin_hash = extensions.crypt('SEU_NOVO_PIN', extensions.gen_salt('bf'))
 where nome = 'Wallace';
```

Repita para cada pessoa da equipe e para o perfil do dono.

### Deploy

Qualquer hospedagem estática funciona, sem configuração adicional:

| Plataforma | Como publicar |
|---|---|
| **Vercel** | Importar o repositório (sem *build command*, diretório de saída `.`) |
| **Netlify** | Importar o repositório (diretório de publicação `.`) |
| **GitHub Pages** | *Settings → Pages → Deploy from branch → `main` / root* |
| **Cloudflare Pages** | Conectar o repositório, sem *framework preset* |

---

## Customização

| O que mudar | Onde |
|---|---|
| Serviços, preços e duração | Tabela `servicos` (SQL Editor ou *Table Editor*) |
| Equipe | Tabela `barbeiros`; fotos em `fotos/<nome>.webp` (o nome da foto é associado ao nome do barbeiro) |
| Horário de funcionamento e dias fechados | Funções `ocupacao`, `criar_agendamento` e `remarcar_meu` (`dow in (0, 1)`) |
| Regra de fidelidade | Função `fidelidade` (o limite de 10 serviços) |
| Cores | Variáveis `--ouro` / `--ouro-esc` em `tema.css` e `tailwind.config` nos HTMLs |
| Endereço, Instagram e telefone | Seção de contato do `index.html` |

---

## Roadmap

- [ ] Limitar tentativas de PIN no `painel_login` (*rate limit*) e migrar o painel para **Supabase Auth**.
- [ ] Lembrete automático por WhatsApp antes do horário.
- [ ] Relatórios semanais e mensais por barbeiro e por serviço.
- [ ] Tailwind com *build* e *purge*, no lugar do CDN.
- [ ] Testes automatizados das funções SQL (disponibilidade, fidelidade e conflitos).
- [ ] Notificações *push* no painel para novos agendamentos.

---

## Informações do negócio

| | |
|---|---|
| **Barbearia** | Mega Barba — Barbearia Tradicional |
| **Endereço** | R. Cachambi, 228A, Cachambi, Rio de Janeiro – RJ, CEP 21751-180 |
| **Horário** | Terça a sábado, das 09h às 19h |
| **Instagram** | [@mega_barba](https://www.instagram.com/mega_barba/) |

---

## Licença

© Mega Barba. Todos os direitos reservados.

O código-fonte, a identidade visual e os materiais deste repositório são de uso exclusivo do proprietário.
