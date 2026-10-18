# WhatsCrânio

Cliente macOS multi-conta para o WhatsApp Web, com mensagens rápidas, agendamentos, filas de envio e bloqueio local por senha.

O WhatsCrânio mantém cada conta em uma sessão WebKit persistente e isolada. A troca de contas e as ferramentas do aplicativo ficam integradas à barra lateral do próprio WhatsApp Web, preservando espaço para as conversas.

> Projeto independente e não oficial. WhatsApp é uma marca da Meta Platforms, Inc. Este projeto não é afiliado, patrocinado nem aprovado pela Meta ou pelo WhatsApp.

## Recursos

- múltiplas contas do WhatsApp Web no mesmo aplicativo;
- sessões, cookies e armazenamento separados por conta;
- edição do nome e da cor de cada conta sem remover a sessão;
- abertura de links `whatsapp://` com seleção da conta de destino;
- notificações nativas de novas mensagens, com nome do contato e prévia;
- ícone na barra de menus com contador de mensagens não lidas;
- mensagens rápidas organizadas por categorias e pesquisa;
- anexos de imagem ou documento com legenda automática;
- agendamento com confirmação manual ou envio automático;
- captura do contato ativo ao criar um agendamento;
- filas de macro compostas por mensagens rápidas existentes;
- busca em mensagens rápidas e filas;
- gravação de áudio fornecida pelo próprio WhatsApp Web;
- bloqueio imediato pela barra lateral;
- bloqueio automático entre 1 e 120 minutos de inatividade;
- senha de bloqueio protegida pelo Chaveiro do macOS;
- página de apoio ao desenvolvedor com QR Code Pix e código copia e cola;
- interface compacta e integrada ao WhatsApp Web.

## Requisitos

- macOS 14 ou posterior;
- Xcode Command Line Tools com Swift 6;
- uma conta válida do WhatsApp para cada sessão conectada.

## Executar durante o desenvolvimento

```bash
swift run WhatsCranio
```

## Testes

```bash
swift test
```

Os testes cobrem compatibilidade dos agendamentos, persistência do modo automático, validação da senha, troca e remoção de credenciais, rejeição de senha incorreta, tempo do bloqueio automático, leitura do QR Code Pix e conversão segura de links `whatsapp://`, `api.whatsapp.com` e `wa.me`.

## Gerar o aplicativo

```bash
./build-app.sh
open "dist/WhatsCrânio.app"
```

O script cria um bundle em `dist/WhatsCrânio.app` e aplica uma assinatura local ad hoc. O ícone é gerado a partir do SVG versionado quando um `Resources/AppIcon.icns` local não está disponível.

## Baixar e instalar

1. Abra a seção **Releases** do repositório no GitHub.
2. Baixe `WhatsCranio-macOS.dmg` da versão mais recente.
3. Abra o DMG e arraste **WhatsCrânio** para **Applications**.
4. Ejete a imagem do instalador.

As versões são compiladas pelo GitHub Actions quando uma tag `v*` é publicada. O DMG inclui também um arquivo `.sha256` para conferência de integridade.

### Aviso do Gatekeeper

No momento, as compilações públicas usam assinatura ad hoc porque este projeto ainda não possui um certificado **Developer ID Application** nem credenciais de notarização da Apple. Na primeira abertura, clique com o botão direito no aplicativo, escolha **Abrir** e confirme. Uma instalação sem esse aviso exige assinatura Developer ID e notarização pela Apple.

## Uso básico

1. Abra o aplicativo e conecte a primeira conta pelo QR Code oficial do WhatsApp Web.
2. Use o botão **+** da barra integrada para adicionar outras contas.
3. Use o raio para abrir mensagens rápidas, agendamentos e filas.
4. Use a engrenagem para abrir as preferências.
5. Use o coração para abrir a página de apoio ao desenvolvedor.
6. Configure uma senha em **Preferências → Bloqueio** antes de usar o cadeado.

## Links do WhatsApp

Ao abrir um link do WhatsApp no navegador, o macOS pode encaminhá-lo ao WhatsCrânio por meio do esquema `whatsapp://`. Se houver mais de uma conta, o aplicativo mostra o telefone, a mensagem do link e solicita a conta de destino antes de abrir a conversa.

É possível memorizar a conta escolhida. A escolha pode ser removida em **Preferências → Links do WhatsApp → Perguntar sempre**. A preferência usa o identificador permanente da conta, portanto não depende da posição dela na lista.

## Agendamentos

Ao criar um agendamento, o contato aberto naquele momento é preenchido como destino. O usuário ainda pode substituí-lo explicitamente no modal.

No horário definido, o aplicativo seleciona a conta correta, localiza o contato e somente então prepara ou envia a mensagem. Se o destino ou algum anexo não puder ser confirmado, o agendamento volta para preparação manual em vez de enviar no chat que estiver aberto por acaso.

O envio automático requer que o WhatsCrânio esteja em execução, com a conta conectada e o WhatsApp Web operacional.

## Mensagens rápidas e filas

Mensagens rápidas podem conter texto e anexos. Em imagens e documentos, o texto é preenchido como legenda da prévia. Uma fila de macro executa uma sequência ordenada dessas mensagens para o contato exibido no modal.

Automatizações dependem da interface atual do WhatsApp Web. Mudanças feitas pelo WhatsApp podem exigir ajustes nos seletores e no fluxo de preparação.

## Bloqueio e privacidade

- a senha de bloqueio fica no Chaveiro do macOS, não em arquivos do projeto ou `UserDefaults`;
- o bloqueio cobre e desfoca as conversas;
- uma senha incorreta não libera a interface;
- dados de contas, modelos, filas e agendamentos permanecem localmente no Mac;
- sessões WebKit não são compartilhadas entre as contas;
- o aplicativo não envia credenciais para um servidor próprio.

O bloqueio protege a visualização casual do aplicativo, mas não substitui FileVault, senha de sessão do macOS ou outras proteções do sistema.

## Estrutura

```text
Sources/WhatsCranio/
├── AppLock.swift          # Chaveiro e política de bloqueio
├── AppModel.swift         # Estado, persistência e automações
├── AutomationViews.swift  # Mensagens rápidas, agenda e filas
├── DesktopNotifications.swift # Alertas nativos e barra de menus
├── LocalStore.swift       # Armazenamento local dos modelos
├── PixDonation.swift      # Página de apoio e payload Pix
├── Views.swift            # Interface SwiftUI
├── WebModels.swift        # Modelos de domínio
├── WhatsAppWebView.swift  # Integração com WKWebView
└── WhatsCranioApp.swift   # Entrada e ciclo de vida do app
```

## Avisos

- revise os Termos de Serviço do WhatsApp antes de usar automações;
- evite envios não solicitados ou em massa;
- o projeto não inclui contas, cookies, mensagens, credenciais ou dados pessoais;
- nenhuma equivalência completa com aplicativos comerciais é alegada.
