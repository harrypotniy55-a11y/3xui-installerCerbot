Данный скрипт для автоматической установки Cerbot SSL сертификата для панели 3X-UI

Команда выполнения скрипта: 

curl -fL --retry 3 \
"https://raw.githubusercontent.com/harrypotniy55-a11y/3xui-installerCerbot/refs/heads/main/3xui-ssl-setup.sh" \
-o /tmp/3xui-ssl-setup.sh && \
bash -n /tmp/3xui-ssl-setup.sh && \
bash /tmp/3xui-ssl-setup.sh
