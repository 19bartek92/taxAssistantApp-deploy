# TaxAssistantApp - Azure Deployment

## Quick Deploy to Azure

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2F19bartek92%2FtaxAssistantApp-deploy%2Fmain%2Fazuredeploy.json)

## Rozwiązywanie problemów

### Problem z Key Vault (ConflictError)
Jeśli otrzymujesz błąd "A vault with the same name already exists in deleted state", to oznacza że wcześniej usunąłeś aplikację ale Key Vault pozostał w "soft delete":

**Rozwiązanie 1: Odzyskanie Key Vault (jeśli błąd mówi o existing deleted vault)**
Ustaw parametr `enableKeyVaultRecovery` na `true` podczas deployment.

**Rozwiązanie 2: Nowa instalacja (domyślne)**
Template domyślnie tworzy nowy Key Vault. To działa gdy nie ma konfliktu.

**Rozwiązanie 3: Ręczne wyczyszczenie**
```bash
# Znajdź usunięte Key Vault
az keyvault list-deleted --subscription [YOUR_SUBSCRIPTION_ID]

# Wyczyść definitywnie (UWAGA: to jest nieodwracalne!)
az keyvault purge --name [VAULT_NAME] --location [LOCATION]
```

## Automatyczne wdrożenie z GitHub

Template automatycznie konfiguruje GitHub deployment podczas tworzenia infrastruktury.

### Wymagane dane:
- **GitHub PAT (Personal Access Token)** - token z uprawnieniami do repo
- **API Keys** - klucze NSA Search i Detail

### Jak utworzyć GitHub PAT:
1. Przejdź do GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Kliknij **Generate new token (classic)**
3. Wybierz scope: `repo` (Full control of private repositories)
4. Skopiuj wygenerowany token

### Proces deployment:
1. **Deploy to Azure** → podaj wszystkie wymagane parametry (w tym GitHub PAT)
2. Azure automatycznie:
   - Tworzy App Service i Key Vault
   - Konfiguruje GitHub deployment z continuous integration
   - Pobiera i buduje kod z repository
   - Uruchamia aplikację

### Aktualizacje aplikacji:
- **Automatyczne:** Każdy push do branch `main` wyzwala deployment
- **Manualne:** Azure Portal → App Service → Deployment Center → Sync

## Parametry konfiguracji

| Parametr | Opis | Wartość domyślna |
|----------|------|------------------|
| `webAppName` | Nazwa aplikacji | `taxassistant-{uniqueString}` |
| `sku` | Plan App Service | `F1` (Free) |
| `location` | Region Azure | `West Europe` |
| `enableKeyVaultRecovery` | Odzyskaj Key Vault | `false` |
| `gitHubPat` | GitHub Personal Access Token | (wymagane) |
| `nsaSearchApiKey` | Klucz API NSA Search | (wymagane) |
| `nsaDetailApiKey` | Klucz API NSA Detail | (wymagane) |

## Zarządzanie kluczami API

Po wdrożeniu możesz zmienić klucze API w Key Vault:

1. Przejdź do Azure Portal → Key Vault
2. Otwórz sekcję "Secrets"
3. Edytuj `nsa-search-key` lub `nsa-detail-key`
4. Restart aplikacji żeby zastosować zmiany

## Koszty

- **F1 (Free)**: Bezpłatny plan, ograniczenia: 60 minut CPU/dzień, 1GB RAM
- **B1 (Basic)**: ~€13/miesiąc, bez ograniczeń czasowych
- **S1 (Standard)**: ~€56/miesiąc, autoscaling, custom domains

## Wsparcie

Jeśli masz problemy z wdrożeniem, sprawdź:
1. Czy masz odpowiednie uprawnienia w Azure
2. Czy klucze API są poprawne
3. Logi aplikacji w Azure Portal → App Service → Log stream