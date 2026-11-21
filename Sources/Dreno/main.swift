import Foundation

// Modo linha de comando (testes e relatórios) antes de subir a interface.
if let code = CLI.run(CommandLine.arguments) {
    exit(code)
}
DrenoApp.main()
