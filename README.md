# WhatsCrânio

Cliente macOS multi-conta para o WhatsApp Web, com mensagens rápidas, agendamentos, filas de envio e bloqueio local por senha.

O WhatsCrânio mantém cada conta em uma sessão WebKit persistente e isolada. A troca de contas e as ferramentas do aplicativo ficam integradas à barra lateral do próprio WhatsApp Web, preservando espaço para as conversas.

> Projeto independente e não oficial. WhatsApp é uma marca da Meta Platforms, Inc. Este projeto não é afiliado, patrocinado nem aprovado pela Meta ou pelo WhatsApp.

## Recursos

- múltiplas contas do WhatsApp Web no mesmo aplicativo;
- sessões, cookies e armazenamento separados por conta;
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

Os testes cobrem compatibilidade dos agendamentos, persistência do modo automático, validação da senha, troca e remoção de credenciais, rejeição de senha incorreta e o tempo do bloqueio automático.

## Gerar o aplicativo

```bash
./build-app.sh
open "dist/WhatsCrânio.app"
```

O script cria um bundle em `dist/WhatsCrânio.app` e aplica uma assinatura local ad hoc. Se `Resources/AppIcon.icns` estiver presente, ele também será incluído no bundle; sem esse arquivo, o macOS usa o ícone genérico de aplicativo.

## Uso básico

1. Abra o aplicativo e conecte a primeira conta pelo QR Code oficial do WhatsApp Web.
2. Use o botão **+** da barra integrada para adicionar outras contas.
3. Use o raio para abrir mensagens rápidas, agendamentos e filas.
4. Use a engrenagem para abrir as preferências.
5. Configure uma senha em **Preferências → Bloqueio** antes de usar o cadeado.

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
├── LocalStore.swift       # Armazenamento local dos modelos
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
