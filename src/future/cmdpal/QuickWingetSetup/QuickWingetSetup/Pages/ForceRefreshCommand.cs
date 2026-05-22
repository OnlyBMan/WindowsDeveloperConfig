using Microsoft.CommandPalette.Extensions;
using Microsoft.CommandPalette.Extensions.Toolkit;
using QuickWingetSetup.Services;

namespace QuickWingetSetup;

internal sealed partial class RefreshCacheCommand : InvokableCommand
{
    private readonly ScriptFetchService _fetchService;
    private readonly QuickWingetSetupPage _page;

    public RefreshCacheCommand(ScriptFetchService fetchService, QuickWingetSetupPage page)
    {
        _fetchService = fetchService;
        _page = page;
    }

    public override ICommandResult Invoke()
    {
        _fetchService.ForceRefreshAsync().GetAwaiter().GetResult();
        _page.RefreshItems();
        return CommandResult.KeepOpen();
    }
}
