CocktailBot Pi4 - Native Linux ARM64 Performance Test

1. .github/workflows/build-linux-arm64-test.yml in das Repo cocktailbotapppi4 hochladen/committen.
2. GitHub -> Actions -> "Build Native Linux ARM64 Test" -> Run workflow.
3. Der Workflow baut separat und veröffentlicht den Testball auf Branch native-linux-arm64-test.
4. run-native-test.sh und stop-native-test.sh in ~/cocktailbotapppi4 ablegen.
5. Auf dem Pi:
     cd ~/cocktailbotapppi4
     chmod +x run-native-test.sh stop-native-test.sh
     ./run-native-test.sh
6. Während des Scrollens in einem zweiten SSH-Fenster:
     pidstat -p "$(cat /tmp/cocktailbot-native-test.pid)" 1 8
7. Zurück zur Web-Version:
     cd ~/cocktailbotapppi4
     ./stop-native-test.sh
   Falls Chromium nicht automatisch wiederkommt:
     sudo reboot

Der normale web-release Branch und /opt/cocktailbot werden nicht ersetzt.
Der Backenddienst auf Port 8080 bleibt während des Tests aktiv.
