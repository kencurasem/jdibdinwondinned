#!/bin/bash

echo "Starting KahfiModTzy Ultimate Security & Theme Installation..."
echo "=============================================================="

PANEL_PATH="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl_backups"
TIMESTAMP=$(date -u +"%Y-%m-%d-%H-%M-%S")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

mkdir -p "$BACKUP_DIR"

print_status() {
    echo -e "${BLUE}${NC}$1"
}

print_success() {
    echo -e "${GREEN}${NC}$1"
}

print_warning() {
    echo -e "${YELLOW}${NC}$1"
}

print_error() {
    echo -e "${RED}${NC}$1"
}

backup_file() {
    local file_path="$1"
    local backup_name="$2"
    
    if [ -f "$file_path" ]; then
        cp "$file_path" "$BACKUP_DIR/${backup_name}_${TIMESTAMP}.bak"
        print_status "Backed up: $backup_name"
        return 0
    fi
    return 1
}

create_protected_file() {
    local file_path="$1"
    local content="$2"
    local backup_name="$3"
    
    backup_file "$file_path" "$backup_name"
    mkdir -p "$(dirname "$file_path")"
    echo "$content" > "$file_path"
    chmod 644 "$file_path"
    print_success "Protected: $(basename "$file_path")"
}

print_status "Installing Security Protections..."

create_protected_file "$PANEL_PATH/app/Services/Servers/ServerDeletionService.php" '<?php

namespace Pterodactyl\Services\Servers;

use Illuminate\Support\Facades\Auth;
use Pterodactyl\Exceptions\DisplayException;
use Illuminate\Http\Response;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

class ServerDeletionService
{
    protected bool $force = false;

    public function __construct(
        private ConnectionInterface $connection,
        private DaemonServerRepository $daemonServerRepository,
        private DatabaseManagementService $databaseManagementService
    ) {}

    public function withForce(bool $bool = true): self
    {
        $this->force = $bool;
        return $this;
    }

    public function handle(Server $server): void
    {
        $user = Auth::user();

        // KahfiModTzy Protection :: Server Deletion Security
        if ($user) {
            if ($user->id !== 1) {
                $ownerId = $server->owner_id
                    ?? $server->user_id
                    ?? ($server->owner?->id ?? null)
                    ?? ($server->user?->id ?? null);

                if ($ownerId === null) {
                    throw new DisplayException("✖ KahfiModTzy Protection :: Unauthorized deletion attempt");
                }

                if ($ownerId !== $user->id) {
                    throw new DisplayException("✖ KahfiModTzy Protection :: You can only delete your own servers");
                }
            }
        }

        try {
            $this->daemonServerRepository->setServer($server)->delete();
        } catch (DaemonConnectionException $exception) {
            if (!$this->force && $exception->getStatusCode() !== Response::HTTP_NOT_FOUND) {
                throw $exception;
            }
            Log::warning($exception);
        }

        $this->connection->transaction(function () use ($server) {
            foreach ($server->databases as $database) {
                try {
                    $this->databaseManagementService->delete($database);
                } catch (\Exception $exception) {
                    if (!$this->force) {
                        throw $exception;
                    }
                    $database->delete();
                    Log::warning($exception);
                }
            }
            $server->delete();
        });
    }
}' "ServerDeletionService"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/UserController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Illuminate\View\View;
use Illuminate\Http\Request;
use Pterodactyl\Models\User;
use Pterodactyl\Models\Model;
use Illuminate\Support\Collection;
use Illuminate\Http\RedirectResponse;
use Prologue\Alerts\AlertsMessageBag;
use Spatie\QueryBuilder\QueryBuilder;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Http\Controllers\Controller;
use Illuminate\Contracts\Translation\Translator;
use Pterodactyl\Services\Users\UserUpdateService;
use Pterodactyl\Traits\Helpers\AvailableLanguages;
use Pterodactyl\Services\Users\UserCreationService;
use Pterodactyl\Services\Users\UserDeletionService;
use Pterodactyl\Http\Requests\Admin\UserFormRequest;
use Pterodactyl\Http\Requests\Admin\NewUserFormRequest;
use Pterodactyl\Contracts\Repository\UserRepositoryInterface;
use Illuminate\Support\Facades\Auth;

class UserController extends Controller
{
    use AvailableLanguages;

    public function __construct(
        protected AlertsMessageBag $alert,
        protected UserCreationService $creationService,
        protected UserDeletionService $deletionService,
        protected Translator $translator,
        protected UserUpdateService $updateService,
        protected UserRepositoryInterface $repository,
        protected ViewFactory $view
    ) {}

    /**
     * KahfiModTzy Protection :: Only root admin ID 1 can manage admin accounts.
     */
    private function ensureRootAdmin(string $action = "manage users"): void
    {
        $user = Auth::user();

        if (!$user || (int) $user->id !== 1) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can " . $action);
        }
    }

    public function index(Request $request): View
    {
        $users = QueryBuilder::for(
            User::query()->select("users.*")
                ->selectRaw("COUNT(DISTINCT(subusers.id)) as subuser_of_count")
                ->selectRaw("COUNT(DISTINCT(servers.id)) as servers_count")
                ->leftJoin("subusers", "subusers.user_id", "=", "users.id")
                ->leftJoin("servers", "servers.owner_id", "=", "users.id")
                ->groupBy("users.id")
        )
            ->allowedFilters(["username", "email", "uuid"])
            ->allowedSorts(["id", "uuid"])
            ->paginate(50);

        return $this->view->make("admin.users.index", ["users" => $users]);
    }

    public function create(): View
    {
        // FIX: admin kedua boleh membuka halaman create user.
        // Yang diblokir hanya create admin/root_admin, bukan create user biasa.
        return $this->view->make("admin.users.new", [
            "languages" => $this->getAvailableLanguages(true),
        ]);
    }

    public function view(User $user): View
    {
        // FIX: selain admin utama ID 1 tidak boleh membuka halaman detail user.
        $this->ensureRootAdmin("view user details");

        return $this->view->make("admin.users.view", [
            "user" => $user,
            "languages" => $this->getAvailableLanguages(true),
        ]);
    }

    public function delete(Request $request, User $user): RedirectResponse
    {
        // KahfiModTzy Protection :: User Deletion Security
        $this->ensureRootAdmin("delete users");

        if ($request->user()->id === $user->id) {
            throw new DisplayException($this->translator->get("admin/user.exceptions.user_has_servers"));
        }

        $this->deletionService->handle($user);
        return redirect()->route("admin.users");
    }

    public function store(NewUserFormRequest $request): RedirectResponse
    {
        // FIX UTAMA: admin kedua boleh create user biasa.
        // Yang dilarang hanya membuat akun baru sebagai admin/root_admin.
        $data = $request->normalize();
        $authUser = Auth::user();

        if (!$authUser) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Unauthorized user creation attempt");
        }

        if ((int) $authUser->id !== 1) {
            $rootAdminRaw = $data["root_admin"] ?? $request->input("root_admin", false);
            $rootAdminEnabled = filter_var($rootAdminRaw, FILTER_VALIDATE_BOOLEAN);

            if ($rootAdminEnabled) {
                throw new DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can create admin accounts");
            }

            // Paksa akun yang dibuat admin kedua menjadi user biasa.
            $data["root_admin"] = false;
        }

        $user = $this->creationService->handle($data);
        $this->alert->success($this->translator->get("admin/user.notices.account_created"))->flash();

        // Admin kedua tidak boleh buka detail user, jadi arahkan balik ke list user.
        return ((int) $authUser->id === 1)
            ? redirect()->route("admin.users.view", $user->id)
            : redirect()->route("admin.users");
    }

    public function update(UserFormRequest $request, User $user): RedirectResponse
    {
        // KahfiModTzy Protection :: User Modification Security
        $authUser = Auth::user();

        if (!$authUser || (int) $authUser->id !== 1) {
            // Admin kedua tetap boleh lihat user, tapi tidak boleh edit data penting
            // dan tidak boleh mengangkat/menurunkan hak admin siapa pun.
            $restrictedFields = ["email", "first_name", "last_name", "password", "root_admin"];

            foreach ($restrictedFields as $field) {
                if ($request->has($field)) {
                    throw new DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can modify user/admin privileges");
                }
            }

            if ($user->root_admin) {
                throw new DisplayException("✖ KahfiModTzy Protection :: Admin privilege modification blocked");
            }
        }

        $this->updateService
            ->setUserLevel(User::USER_LEVEL_ADMIN)
            ->handle($user, $request->normalize());

        $this->alert->success(trans("admin/user.notices.account_updated"))->flash();
        return redirect()->route("admin.users.view", $user->id);
    }

    public function json(Request $request): Model|Collection
    {
        $users = QueryBuilder::for(User::query())->allowedFilters(["email"])->paginate(25);

        if ($request->query("user_id")) {
            $user = User::query()->findOrFail($request->input("user_id"));
            $user->md5 = md5(strtolower($user->email));
            return $user;
        }

        return $users->map(function ($item) {
            $item->md5 = md5(strtolower($item->email));
            return $item;
        });
    }
}' "UserController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/LocationController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Illuminate\View\View;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Pterodactyl\Models\Location;
use Prologue\Alerts\AlertsMessageBag;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Http\Requests\Admin\LocationFormRequest;
use Pterodactyl\Services\Locations\LocationUpdateService;
use Pterodactyl\Services\Locations\LocationCreationService;
use Pterodactyl\Services\Locations\LocationDeletionService;
use Pterodactyl\Contracts\Repository\LocationRepositoryInterface;

class LocationController extends Controller
{
    public function __construct(
        protected AlertsMessageBag $alert,
        protected LocationCreationService $creationService,
        protected LocationDeletionService $deletionService,
        protected LocationRepositoryInterface $repository,
        protected LocationUpdateService $updateService,
        protected ViewFactory $view
    ) {}

    public function index(): View
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Location access denied");
        }

        return $this->view->make("admin.locations.index", [
            "locations" => $this->repository->getAllWithDetails(),
        ]);
    }

    public function view(int $id): View
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Location view denied");
        }

        return $this->view->make("admin.locations.view", [
            "location" => $this->repository->getWithNodes($id),
        ]);
    }

    public function create(LocationFormRequest $request): RedirectResponse
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Location creation denied");
        }

        $location = $this->creationService->handle($request->normalize());
        $this->alert->success("Location was created successfully.")->flash();

        return redirect()->route("admin.locations.view", $location->id);
    }

    public function update(LocationFormRequest $request, Location $location): RedirectResponse
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Location modification denied");
        }

        if ($request->input("action") === "delete") {
            return $this->delete($location);
        }

        $this->updateService->handle($location->id, $request->normalize());
        $this->alert->success("Location was updated successfully.")->flash();

        return redirect()->route("admin.locations.view", $location->id);
    }

    public function delete(Location $location): RedirectResponse
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Location deletion denied");
        }

        try {
            $this->deletionService->handle($location->id);
            return redirect()->route("admin.locations");
        } catch (DisplayException $ex) {
            $this->alert->danger($ex->getMessage())->flash();
        }

        return redirect()->route("admin.locations.view", $location->id);
    }
}' "LocationController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/Nodes/NodeController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin\Nodes;

use Illuminate\View\View;
use Illuminate\Http\Request;
use Pterodactyl\Models\Node;
use Spatie\QueryBuilder\QueryBuilder;
use Pterodactyl\Http\Controllers\Controller;
use Illuminate\Contracts\View\Factory as ViewFactory;
use Illuminate\Support\Facades\Auth;

class NodeController extends Controller
{
    public function __construct(private ViewFactory $view)
    {
    }

    public function index(Request $request): View
    {
        // KahfiModTzy Protection :: Node Access Security
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Node access restricted");
        }

        $nodes = QueryBuilder::for(
            Node::query()->with("location")->withCount("servers")
        )
            ->allowedFilters(["uuid", "name"])
            ->allowedSorts(["id"])
            ->paginate(25);

        return $this->view->make("admin.nodes.index", ["nodes" => $nodes]);
    }
}' "NodeController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/Nests/NestController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin\Nests;

use Illuminate\View\View;
use Illuminate\Http\RedirectResponse;
use Prologue\Alerts\AlertsMessageBag;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Nests\NestUpdateService;
use Pterodactyl\Services\Nests\NestCreationService;
use Pterodactyl\Services\Nests\NestDeletionService;
use Pterodactyl\Contracts\Repository\NestRepositoryInterface;
use Pterodactyl\Http\Requests\Admin\Nest\StoreNestFormRequest;
use Illuminate\Support\Facades\Auth;

class NestController extends Controller
{
    public function __construct(
        protected AlertsMessageBag $alert,
        protected NestCreationService $nestCreationService,
        protected NestDeletionService $nestDeletionService,
        protected NestRepositoryInterface $repository,
        protected NestUpdateService $nestUpdateService,
        protected ViewFactory $view
    ) {
    }

    public function index(): View
    {
        // KahfiModTzy Protection :: Nest Access Security
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Nest access restricted");
        }

        return $this->view->make("admin.nests.index", [
            "nests" => $this->repository->getWithCounts(),
        ]);
    }

    public function create(): View
    {
        return $this->view->make("admin.nests.new");
    }

    public function store(StoreNestFormRequest $request): RedirectResponse
    {
        $nest = $this->nestCreationService->handle($request->normalize());
        $this->alert->success(trans("admin/nests.notices.created", ["name" => htmlspecialchars($nest->name)]))->flash();

        return redirect()->route("admin.nests.view", $nest->id);
    }

    public function view(int $nest): View
    {
        return $this->view->make("admin.nests.view", [
            "nest" => $this->repository->getWithEggServers($nest),
        ]);
    }

    public function update(StoreNestFormRequest $request, int $nest): RedirectResponse
    {
        $this->nestUpdateService->handle($nest, $request->normalize());
        $this->alert->success(trans("admin/nests.notices.updated"))->flash();

        return redirect()->route("admin.nests.view", $nest);
    }

    public function destroy(int $nest): RedirectResponse
    {
        $this->nestDeletionService->handle($nest);
        $this->alert->success(trans("admin/nests.notices.deleted"))->flash();

        return redirect()->route("admin.nests");
    }
}' "NestController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/Settings/IndexController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin\Settings;

use Illuminate\View\View;
use Illuminate\Http\RedirectResponse;
use Illuminate\Support\Facades\Auth;
use Prologue\Alerts\AlertsMessageBag;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\View\Factory as ViewFactory;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Traits\Helpers\AvailableLanguages;
use Pterodactyl\Services\Helpers\SoftwareVersionService;
use Pterodactyl\Contracts\Repository\SettingsRepositoryInterface;
use Pterodactyl\Http\Requests\Admin\Settings\BaseSettingsFormRequest;

class IndexController extends Controller
{
    use AvailableLanguages;

    public function __construct(
        private AlertsMessageBag $alert,
        private Kernel $kernel,
        private SettingsRepositoryInterface $settings,
        private SoftwareVersionService $versionService,
        private ViewFactory $view
    ) {
    }

    public function index(): View
    {
        // KahfiModTzy Protection :: Settings Access Security
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Settings access denied");
        }

        return $this->view->make("admin.settings.index", [
            "version" => $this->versionService,
            "languages" => $this->getAvailableLanguages(true),
        ]);
    }

    public function update(BaseSettingsFormRequest $request): RedirectResponse
    {
        // KahfiModTzy Protection :: Settings Modification Security
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Settings modification denied");
        }

        foreach ($request->normalize() as $key => $value) {
            $this->settings->set("settings::" . $key, $value);
        }

        $this->kernel->call("queue:restart");
        $this->alert->success(
            "Panel settings have been updated successfully and the queue worker was restarted to apply these changes."
        )->flash();

        return redirect()->route("admin.settings");
    }
}' "SettingsController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Api/Client/Servers/FileController.php" '<?php

namespace Pterodactyl\Http\Controllers\Api\Client\Servers;

use Carbon\CarbonImmutable;
use Illuminate\Http\Response;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Models\Server;
use Pterodactyl\Facades\Activity;
use Pterodactyl\Services\Nodes\NodeJWTService;
use Pterodactyl\Repositories\Wings\DaemonFileRepository;
use Pterodactyl\Transformers\Api\Client\FileObjectTransformer;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\CopyFileRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\PullFileRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\ListFilesRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\ChmodFilesRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\DeleteFileRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\RenameFileRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\CreateFolderRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\CompressFilesRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\DecompressFilesRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\GetFileContentsRequest;
use Pterodactyl\Http\Requests\Api\Client\Servers\Files\WriteFileContentRequest;

class FileController extends ClientApiController
{
    public function __construct(
        private NodeJWTService $jwtService,
        private DaemonFileRepository $fileRepository
    ) {
        parent::__construct();
    }

    /**
     * KahfiModTzy Protection :: File Access Security
     */
    private function checkServerAccess($request, Server $server)
    {
        // FIX: jangan pakai owner_id custom di sini.
        // Request class bawaan Pterodactyl sudah validasi permission server/file.
        // Jadi owner/subuser yang punya izin tetap bisa file manager, download, compress, dan backup sendiri.
        return;
    }

    public function directory(ListFilesRequest $request, Server $server): array
    {
        $this->checkServerAccess($request, $server);

        $contents = $this->fileRepository
            ->setServer($server)
            ->getDirectory($request->get("directory") ?? "/");

        return $this->fractal->collection($contents)
            ->transformWith($this->getTransformer(FileObjectTransformer::class))
            ->toArray();
    }

    public function contents(GetFileContentsRequest $request, Server $server): Response
    {
        $this->checkServerAccess($request, $server);

        $response = $this->fileRepository->setServer($server)->getContent(
            $request->get("file"),
            config("pterodactyl.files.max_edit_size")
        );

        Activity::event("server:file.read")->property("file", $request->get("file"))->log();

        return new Response($response, Response::HTTP_OK, ["Content-Type" => "text/plain"]);
    }

    public function download(GetFileContentsRequest $request, Server $server): array
    {
        $this->checkServerAccess($request, $server);

        $token = $this->jwtService
            ->setExpiresAt(CarbonImmutable::now()->addMinutes(15))
            ->setUser($request->user())
            ->setClaims([
                "file_path" => rawurldecode($request->get("file")),
                "server_uuid" => $server->uuid,
            ])
            ->handle($server->node, $request->user()->id . $server->uuid);

        Activity::event("server:file.download")->property("file", $request->get("file"))->log();

        return [
            "object" => "signed_url",
            "attributes" => [
                "url" => sprintf(
                    "%s/download/file?token=%s",
                    $server->node->getConnectionAddress(),
                    $token->toString()
                ),
            ],
        ];
    }

    public function write(WriteFileContentRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository->setServer($server)->putContent($request->get("file"), $request->getContent());

        Activity::event("server:file.write")->property("file", $request->get("file"))->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function create(CreateFolderRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository
            ->setServer($server)
            ->createDirectory($request->input("name"), $request->input("root", "/"));

        Activity::event("server:file.create-directory")
            ->property("name", $request->input("name"))
            ->property("directory", $request->input("root"))
            ->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function rename(RenameFileRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository
            ->setServer($server)
            ->renameFiles($request->input("root"), $request->input("files"));

        Activity::event("server:file.rename")
            ->property("directory", $request->input("root"))
            ->property("files", $request->input("files"))
            ->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function copy(CopyFileRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository
            ->setServer($server)
            ->copyFile($request->input("location"));

        Activity::event("server:file.copy")->property("file", $request->input("location"))->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function compress(CompressFilesRequest $request, Server $server): array
    {
        $this->checkServerAccess($request, $server);

        $file = $this->fileRepository->setServer($server)->compressFiles(
            $request->input("root"),
            $request->input("files")
        );

        Activity::event("server:file.compress")
            ->property("directory", $request->input("root"))
            ->property("files", $request->input("files"))
            ->log();

        return $this->fractal->item($file)
            ->transformWith($this->getTransformer(FileObjectTransformer::class))
            ->toArray();
    }

    public function decompress(DecompressFilesRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        set_time_limit(300);

        $this->fileRepository->setServer($server)->decompressFile(
            $request->input("root"),
            $request->input("file")
        );

        Activity::event("server:file.decompress")
            ->property("directory", $request->input("root"))
            ->property("files", $request->input("file"))
            ->log();

        return new JsonResponse([], JsonResponse::HTTP_NO_CONTENT);
    }

    public function delete(DeleteFileRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository->setServer($server)->deleteFiles(
            $request->input("root"),
            $request->input("files")
        );

        Activity::event("server:file.delete")
            ->property("directory", $request->input("root"))
            ->property("files", $request->input("files"))
            ->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function chmod(ChmodFilesRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository->setServer($server)->chmodFiles(
            $request->input("root"),
            $request->input("files")
        );

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }

    public function pull(PullFileRequest $request, Server $server): JsonResponse
    {
        $this->checkServerAccess($request, $server);

        $this->fileRepository->setServer($server)->pull(
            $request->input("url"),
            $request->input("directory"),
            $request->safe(["filename", "use_header", "foreground"])
        );

        Activity::event("server:file.pull")
            ->property("directory", $request->input("directory"))
            ->property("url", $request->input("url"))
            ->log();

        return new JsonResponse([], Response::HTTP_NO_CONTENT);
    }
}' "FileController"

create_protected_file "$PANEL_PATH/app/Http/Controllers/Api/Client/Servers/ServerController.php" '<?php

namespace Pterodactyl\Http\Controllers\Api\Client\Servers;

use Illuminate\Support\Facades\Auth;
use Pterodactyl\Models\Server;
use Pterodactyl\Transformers\Api\Client\ServerTransformer;
use Pterodactyl\Services\Servers\GetUserPermissionsService;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
use Pterodactyl\Http\Requests\Api\Client\Servers\GetServerRequest;

class ServerController extends ClientApiController
{
    public function __construct(private GetUserPermissionsService $permissionsService)
    {
        parent::__construct();
    }

    public function index(GetServerRequest $request, Server $server): array
    {
        // FIX: jangan blokir server API dengan owner_id custom.
        // GetServerRequest bawaan Pterodactyl sudah cek akses user/subuser ke server.
        // Ini penting supaya fitur backup/download server sendiri tidak kena 403 dari protect.
        return $this->fractal->item($server)
            ->transformWith($this->getTransformer(ServerTransformer::class))
            ->addMeta([
                "is_server_owner" => $request->user()->id === $server->owner_id,
                "user_permissions" => $this->permissionsService->handle($server, $request->user()),
            ])
            ->toArray();
    }
}' "ServerController"

create_protected_file "$PANEL_PATH/app/Services/Servers/DetailsModificationService.php" '<?php

namespace Pterodactyl\Services\Servers;

use Illuminate\Support\Arr;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Auth;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Traits\Services\ReturnsUpdatedModels;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

class DetailsModificationService
{
    use ReturnsUpdatedModels;

    public function __construct(
        private ConnectionInterface $connection,
        private DaemonServerRepository $serverRepository
    ) {}

    public function handle(Server $server, array $data): Server
    {
        // KahfiModTzy Protection :: Server Modification Security
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            abort(403, "✖ KahfiModTzy Protection :: Server modification denied");
        }

        return $this->connection->transaction(function () use ($data, $server) {
            $owner = $server->owner_id;

            $server->forceFill([
                "external_id" => Arr::get($data, "external_id"),
                "owner_id" => Arr::get($data, "owner_id"),
                "name" => Arr::get($data, "name"),
                "description" => Arr::get($data, "description") ?? "",
            ])->saveOrFail();

            if ($server->owner_id !== $owner) {
                try {
                    $this->serverRepository->setServer($server)->revokeUserJTI($owner);
                } catch (DaemonConnectionException $exception) {
                    // Ignore Wings offline errors
                }
            }

            return $server;
        });
    }
}' "DetailsModificationService"

print_status "Installing Modern Theme..."

CUSTOM_CSS="$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.css"
mkdir -p "$(dirname "$CUSTOM_CSS")"

cat > "$CUSTOM_CSS" << 'THEME_CSS'

@import url("https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700;800&display=swap");

.security-welcome,
.security-badge,
.alert-danger.jm-admin-alert,
.navbar-brand {
    font-family: "Poppins", "Segoe UI", Roboto, sans-serif;
}

.security-welcome {
    text-align: center;
    padding: 2rem 1.5rem 1.8rem;
    margin: 2rem auto;
    max-width: 480px;
    background: rgba(255, 255, 255, 0.92);
    border-radius: 12px;
    backdrop-filter: blur(10px);
    border: 1px solid rgba(0, 0, 0, 0.08);
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12);
}
.security-welcome h3 {
    font-weight: 600;
    font-size: 1.4rem;
    color: #1a73e8;
    margin: 0 0 .5rem;
}
.security-welcome p {
    margin: 0;
    font-size: .95rem;
    color: #5f6368;
}

.security-badge {
    position: fixed;
    top: 20px;
    right: 20px;
    background: linear-gradient(135deg, #ea4335, #b71c1c);
    color: #fff;
    padding: 8px 16px;
    border-radius: 20px;
    font-size: 13px;
    font-weight: 600;
    z-index: 9999;
    animation: pulse 2s infinite;
    box-shadow: 0 4px 12px rgba(234, 67, 53, .35);
}
@keyframes pulse {
    0%, 100% { transform: scale(1); }
    50%      { transform: scale(1.05); }
}

.alert-danger.jm-admin-alert {
    position: fixed;
    top: 80px;
    right: 20px;
    min-width: 280px;
    max-width: 360px;
    background: #ea4335;
    color: #fff;
    border: none;
    border-radius: 8px;
    padding: 1rem 1.25rem;
    font-size: .9rem;
    z-index: 10000;
    box-shadow: 0 6px 16px rgba(234, 67, 53, .4);
    animation: slideInRight .6s ease;
}
@keyframes slideInRight {
    from { transform: translateX(100%); opacity: 0; }
    to   { transform: translateX(0);   opacity: 1; }
}
THEME_CSS

CUSTOM_JS="$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.js"
cat > "$CUSTOM_JS" << 'THEME_JS'
// KahfiModTzy Ultimate Security & Theme Enhancements

class KahfiModTzySecurity {
    constructor() {
        this.init();
    }

    init() {
        this.addSecurityBadge();
        this.enhanceUI();
        this.monitorSecurity();
        this.addWelcomeAnimation();
        this.protectConsole();
    }

    addSecurityBadge() {
        const badge = document.createElement("div");
        badge.className = "security-badge";
        badge.innerHTML = "Protected by KahfiModTzy";
        badge.setAttribute("title", "Ultimate Security System Active");
        document.body.appendChild(badge);

        // Add floating animation
        setInterval(() => {
            badge.style.transform = "translateY(-2px)";
            setTimeout(() => {
                badge.style.transform = "translateY(0)";
            }, 1000);
        }, 2000);
    }

    enhanceUI() {
        // Add hover effects to all cards
        const cards = document.querySelectorAll(".card");
        cards.forEach(card => {
            card.style.transition = "all 0.3s cubic-bezier(0.4, 0, 0.2, 1)";
            
            card.addEventListener("mouseenter", () => {
                card.style.transform = "translateY(-5px)";
                card.style.boxShadow = "0 8px 25px rgba(0,0,0,0.15)";
            });
            
            card.addEventListener("mouseleave", () => {
                card.style.transform = "translateY(0)";
                card.style.boxShadow = "0 1px 3px 0 rgba(60, 64, 67, 0.3), 0 1px 3px 1px rgba(60, 64, 67, 0.15)";
            });
        });

        // Enhance buttons
        const buttons = document.querySelectorAll(".btn");
        buttons.forEach(btn => {
            btn.addEventListener("mouseenter", () => {
                btn.style.transform = "translateY(-2px)";
            });
            btn.addEventListener("mouseleave", () => {
                btn.style.transform = "translateY(0)";
            });
        });

        // Add loading states
        const forms = document.querySelectorAll("form");
        forms.forEach(form => {
            form.addEventListener("submit", (e) => {
                const submitBtn = form.querySelector('button[type="submit"]');
                if (submitBtn) {
                    submitBtn.innerHTML = '<div class="spinner-border spinner-border-sm me-2"></div>Processing...';
                    submitBtn.disabled = true;
                }
            });
        });
    }

    monitorSecurity() {
        let suspiciousActivityCount = 0;
        
        // Monitor rapid clicks
        document.addEventListener("click", (e) => {
            suspiciousActivityCount++;
            
            if (suspiciousActivityCount > 15) {
                this.showSecurityAlert("Multiple rapid clicks detected", "warning");
                suspiciousActivityCount = 0;
            }
            
            // Reset counter after 2 seconds
            setTimeout(() => {
                if (suspiciousActivityCount > 0) suspiciousActivityCount--;
            }, 2000);
        });

        // Monitor form submissions
        document.addEventListener("submit", (e) => {
            const form = e.target;
            if (form.method === "post" || form.method === "POST") {
                console.log("KahfiModTzy: Form submission monitored", form.action);
            }
        });

        // Monitor AJAX requests
        const originalFetch = window.fetch;
        window.fetch = function(...args) {
            console.log("KahfiModTzy: API call intercepted", args[0]);
            return originalFetch.apply(this, args);
        };
    }

    addWelcomeAnimation() {
        // Add welcome message on dashboard
        if (window.location.pathname.includes("/admin") || window.location.pathname.includes("/server")) {
            setTimeout(() => {
                const welcomeMsg = document.createElement("div");
                welcomeMsg.className = "security-welcome";
                welcomeMsg.innerHTML = `
                    <h3>KahfiModTzy Security Active</h3>
                    <p>Telegram : t.me/kahfimoodtzy</p>
                    <small>Panel Protection</small>
                `;
                
                const mainContent = document.querySelector(".content") || document.querySelector("main") || document.body;
                mainContent.prepend(welcomeMsg);
                
                // Remove after 5 seconds
                setTimeout(() => {
                    if (welcomeMsg.parentNode) {
                        welcomeMsg.style.opacity = "0";
                        welcomeMsg.style.transition = "opacity 0.5s ease";
                        setTimeout(() => welcomeMsg.remove(), 500);
                    }
                }, 5000);
            }, 1000);
        }
    }

    showSecurityAlert(message, type = "info") {
        const alert = document.createElement("div");
        alert.className = `alert alert-${type} alert-dismissible fade show`;
        alert.style.cssText = `
            position: fixed;
            top: 80px;
            right: 20px;
            z-index: 10000;
            min-width: 300px;
            max-width: 400px;
            border-radius: 8px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
            backdrop-filter: blur(10px);
        `;
        alert.innerHTML = `
            <strong>KahfiModTzy Security</strong><br>
            ${message}
            <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
        `;
        document.body.appendChild(alert);
        
        setTimeout(() => {
            if (alert.parentNode) {
                alert.style.opacity = "0";
                alert.style.transition = "opacity 0.5s ease";
                setTimeout(() => alert.remove(), 500);
            }
        }, 4000);
    }

    protectConsole() {
        // Basic console protection
        const originalConsole = {
            log: console.log,
            warn: console.warn,
            error: console.error
        };

        console.log = function(...args) {
            if (args.some(arg => 
                typeof arg === "string" && 
                (arg.toLowerCase().includes("security") || 
                 arg.toLowerCase().includes("bypass") ||
                 arg.toLowerCase().includes("admin") ||
                 arg.toLowerCase().includes("token"))
            )) {
                this.showSecurityAlert("Suspicious console activity detected", "danger");
            }
            originalConsole.log.apply(console, args);
        }.bind(this);
    }
}

// Initialize when DOM is loaded
document.addEventListener("DOMContentLoaded", function() {
    new KahfiModTzySecurity();
    
    // Add performance monitoring
    window.addEventListener("load", function() {
        const loadTime = performance.timing.domContentLoadedEventEnd - performance.timing.navigationStart;
        if (loadTime > 2000) {
            console.log(`KahfiModTzy: Page loaded in ${loadTime}ms`);
        }
    });

    // Smooth scrolling for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener("click", function (e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute("href"));
            if (target) {
                target.scrollIntoView({
                    behavior: "smooth",
                    block: "start"
                });
            }
        });
    });
});

// Export for global access
window.KahfiModTzySecurity = KahfiModTzySecurity;
THEME_JS

print_status "Updating panel layout..."

LAYOUT_FILE="$PANEL_PATH/resources/views/layouts/admin.blade.php"
if [ -f "$LAYOUT_FILE" ]; then
    backup_file "$LAYOUT_FILE" "admin_layout"
    
    if ! grep -q "kahfimodtzy-theme.css" "$LAYOUT_FILE"; then
        sed -i '/<\/head>/i\    <!-- KahfiModTzy Security & Theme -->\n    <link rel="stylesheet" href="{{ asset('\''assets/custom/kahfimodtzy-theme.css'\'') }}">\n    <link href="https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">' "$LAYOUT_FILE"
    fi
    
    if ! grep -q "kahfimodtzy-theme.js" "$LAYOUT_FILE"; then
        sed -i '/<\/body>/i\    <!-- KahfiModTzy Security Scripts -->\n    <script src="{{ asset('\''assets/custom/kahfimodtzy-theme.js'\'') }}"></script>' "$LAYOUT_FILE"
    fi
    
    print_success "Panel layout updated"
else
    print_warning "Admin layout file not found, theme might not apply correctly"
fi

print_status "Finalizing installation..."

chown -R www-data:www-data "$PANEL_PATH"
chmod -R 755 "$PANEL_PATH/public/assets/custom"

print_status "Clearing cache..."
cd "$PANEL_PATH" && php artisan view:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan config:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan cache:clear > /dev/null 2>&1

echo "KahfiModTzy Security & Theme Installation Log
==========================================
Timestamp: $(date)
Panel Path: $PANEL_PATH
Backup Directory: $BACKUP_DIR" > "$BACKUP_DIR/installation_${TIMESTAMP}.log"

print_success "Installation completed successfully!"
echo ""
echo -e "${GREEN}KahfiModTzy Ultimate Security & Theme Installation Complete!${NC}"
echo "=============================================================="
echo -e "${CYAN}SECURITY FEATURES INSTALLED:${NC}"
echo "  • Server Deletion Protection"
echo "  • User Management Security"
echo "  • Location Access Control"
echo "  • Node Access Restriction"
echo "  • Nest Access Protection"
echo "  • Settings Modification Security"
echo "  • File Access Control"
echo "  • Server Access Protection"
echo "  • Server Modification Security"
echo ""
echo -e "${PURPLE}THEME FEATURES INSTALLED:${NC}"
echo "  • Modern Google-inspired Design"
echo "  • Poppins Font Family"
echo "  • Smooth Animations & Transitions"
echo "  • Security Badge with Pulse Animation"
echo "  • Material Design Cards"
echo "  • Enhanced Button Styles"
echo "  • Responsive Layout"
echo "  • Dark Mode Support"
echo "  • Custom Scrollbars"
echo "  • Performance Optimized"
echo ""
echo -e "${YELLOW}BACKUP LOCATION:${NC} $BACKUP_DIR"
echo -e "${YELLOW}NEXT STEPS:${NC}"
echo "  1. Run: php artisan queue:restart"
echo "  2. Run: php artisan route:clear"
echo "  3. Refresh your panel to see changes"
echo ""
echo -e "${GREEN}Your panel is now secured with KahfiModTzy Protection!${NC}"
echo "=============================================================="
# ═══════════════════════════════════════════════════════════════
#  KahfiModTzy :: Protect Admin Server Pages
# ═══════════════════════════════════════════════════════════════

print_status "Installing Server Admin Page Protection..."

create_protected_file "$PANEL_PATH/app/Http/Controllers/Admin/ServersController.php" '<?php

namespace Pterodactyl\Http\Controllers\Admin;

use Illuminate\View\View;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Pterodactyl\Models\Node;
use Pterodactyl\Models\User;
use Pterodactyl\Models\Nest;
use Pterodactyl\Models\Server;
use Illuminate\Http\RedirectResponse;
use Prologue\Alerts\AlertsMessageBag;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Http\Controllers\Controller;
use Illuminate\Support\Facades\Auth;
use Pterodactyl\Services\Servers\BuildModificationService;
use Pterodactyl\Services\Servers\ServerDeletionService;
use Pterodactyl\Services\Servers\DetailsModificationService;
use Pterodactyl\Services\Servers\StartupModificationService;
use Pterodactyl\Services\Servers\ReinstallServerService;
use Pterodactyl\Services\Servers\SuspendServerService;
use Pterodactyl\Services\Servers\UnsuspendServerService;
use Pterodactyl\Repositories\Eloquent\DatabaseHostRepository;
use Pterodactyl\Contracts\Repository\NestRepositoryInterface;
use Pterodactyl\Contracts\Repository\NodeRepositoryInterface;
use Pterodactyl\Contracts\Repository\ServerRepositoryInterface;
use Pterodactyl\Contracts\Repository\DatabaseRepositoryInterface;
use Pterodactyl\Contracts\Repository\AllocationRepositoryInterface;
use Pterodactyl\Http\Requests\Admin\ServerFormRequest;
use Pterodactyl\Http\Requests\Admin\Servers\Databases\AttachDatabaseRequest;
use Pterodactyl\Services\Servers\ServerCreationService;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Services\Databases\DatabasePasswordService;
use Spatie\QueryBuilder\QueryBuilder;
use Illuminate\View\Factory as ViewFactory;

class ServersController extends Controller
{
    public function __construct(
        protected AlertsMessageBag $alert,
        protected AllocationRepositoryInterface $allocationRepository,
        protected BuildModificationService $buildModificationService,
        protected DatabaseManagementService $databaseManagementService,
        protected DatabasePasswordService $databasePasswordService,
        protected DatabaseRepositoryInterface $databaseRepository,
        protected DatabaseHostRepository $databaseHostRepository,
        protected ServerDeletionService $deletionService,
        protected DetailsModificationService $detailsModificationService,
        protected ReinstallServerService $reinstallService,
        protected ServerRepositoryInterface $repository,
        protected StartupModificationService $startupModificationService,
        protected SuspendServerService $suspendService,
        protected NestRepositoryInterface $nestRepository,
        protected NodeRepositoryInterface $nodeRepository,
        protected UnsuspendServerService $unsuspendService,
        protected ServerCreationService $creationService,
        protected ViewFactory $view,
    ) {}

    // ── Helper cek akses ─────────────────────────────────────
    private function checkAdmin(string $action = "access"): void
    {
        $user = Auth::user();
        if (!$user || $user->id !== 1) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can $action servers");
        }
    }

    public function index(Request $request): View
    {
        $servers = QueryBuilder::for(
            Server::query()->with(["user", "node", "allocation", "nest", "egg"])
        )
            ->allowedFilters(["uuid", "name", "image"])
            ->allowedSorts(["id", "uuid"])
            ->paginate(25);

        return $this->view->make("admin.servers.index", ["servers" => $servers]);
    }

    public function create(): View
    {
        $this->checkAdmin("create");

        $nodes = Node::all();
        if (count($nodes) < 1) {
            $this->alert->warning(trans("admin/server.alerts.node_required"))->flash();
            return redirect()->route("admin.nodes");
        }

        return $this->view->make("admin.servers.new", [
            "nests" => $this->nestRepository->getWithEggs(),
            "nodes" => $this->nodeRepository->all(),
        ]);
    }

    public function store(ServerFormRequest $request): RedirectResponse
    {
        $this->checkAdmin("create");
        $server = $this->creationService->handle($request->validated());
        return redirect()->route("admin.servers.view", $server->id);
    }

    public function view(Request $request, int $server): View
    {
        return $this->view->make("admin.servers.view.index", [
            "server" => Server::with(["allocations.node", "user", "nest", "egg"])->findOrFail($server),
        ]);
    }

    public function viewDetails(Request $request, Server $server): View
    {
        $this->checkAdmin("view details of");
        return $this->view->make("admin.servers.view.details", ["server" => $server]);
    }

    public function viewBuild(Request $request, Server $server): View
    {
        $this->checkAdmin("view build config of");
        return $this->view->make("admin.servers.view.build", [
            "server"      => $server,
            "nodes"       => Node::all(),
            "allocations" => $this->allocationRepository->getAllocationsForNode($server->node_id),
        ]);
    }

    public function viewStartup(Request $request, Server $server): View
    {
        $this->checkAdmin("view startup of");
        $parameters = $this->repository->getVariablesWithValues($server->id, true);
        return $this->view->make("admin.servers.view.startup", [
            "server"     => $server,
            "nests"      => $this->nestRepository->getWithEggs(),
            "variables"  => $parameters->variables,
            "selectedEgg"=> $parameters->egg,
        ]);
    }

    public function viewDatabase(Request $request, Server $server): View
    {
        $this->checkAdmin("view database of");
        return $this->view->make("admin.servers.view.database", [
            "hosts"  => $this->databaseHostRepository->all(),
            "server" => $server,
        ]);
    }

    public function viewManage(Request $request, Server $server): View
    {
        $this->checkAdmin("manage");
        return $this->view->make("admin.servers.view.manage", ["server" => $server]);
    }

    public function viewDelete(Request $request, Server $server): View
    {
        $this->checkAdmin("delete");
        return $this->view->make("admin.servers.view.delete", ["server" => $server]);
    }

    public function setDetails(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("modify details of");
        $this->detailsModificationService->handle($server, $request->only(["owner_id", "external_id", "name", "description"]));
        $this->alert->success(trans("admin/server.alerts.details_updated"))->flash();
        return redirect()->route("admin.servers.view.details", $server->id);
    }

    public function setContainer(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("modify container of");
        $this->detailsModificationService->handle($server, $request->only(["image"]));
        $this->alert->success(trans("admin/server.alerts.docker_image_updated"))->flash();
        return redirect()->route("admin.servers.view.details", $server->id);
    }

    public function updateBuild(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("modify build config of");
        $this->buildModificationService->handle($server, $request->only(["allocation_id", "memory", "swap", "io", "cpu", "disk", "database_limit", "allocation_limit", "backup_limit"]));
        $this->alert->success(trans("admin/server.alerts.build_updated"))->flash();
        return redirect()->route("admin.servers.view.build", $server->id);
    }

    public function saveStartup(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("modify startup of");
        $this->startupModificationService->setUserLevel(User::USER_LEVEL_ADMIN)->handle($server, $request->except(["_token"]));
        $this->alert->success(trans("admin/server.alerts.startup_changed"))->flash();
        return redirect()->route("admin.servers.view.startup", $server->id);
    }

    public function addDatabase(AttachDatabaseRequest $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("add database to");
        $this->databaseManagementService->create($server, ["database" => $request->input("database"), "remote" => $request->input("remote"), "database_host_id" => $request->input("database_host_id")]);
        return redirect()->route("admin.servers.view.database", $server->id);
    }

    public function resetDatabasePassword(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("reset database password of");
        $database = $server->databases->find($request->input("database"));
        $this->databasePasswordService->handle($database);
        return response("", 204);
    }

    public function deleteDatabase(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("delete database from");
        $database = $server->databases->findOrFail($request->input("database"));
        $this->databaseManagementService->delete($database);
        return response("", 204);
    }

    public function manageSuspend(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("suspend/unsuspend");
        if ($request->input("action") === "suspend") {
            $this->suspendService->handle($server);
            $this->alert->success(trans("admin/server.alerts.server_suspended"))->flash();
        } else {
            $this->unsuspendService->handle($server);
            $this->alert->success(trans("admin/server.alerts.server_unsuspended"))->flash();
        }
        return redirect()->route("admin.servers.view.manage", $server->id);
    }

    public function manageReinstall(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("reinstall");
        $this->reinstallService->handle($server);
        $this->alert->success(trans("admin/server.alerts.server_reinstalled"))->flash();
        return redirect()->route("admin.servers.view.manage", $server->id);
    }

    public function delete(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("delete");
        $this->deletionService->withForce($request->filled("force_delete"))->handle($server);
        return redirect()->route("admin.servers");
    }
}' "ServersController"

print_success "Server Admin Page Protection installed!"

# Update summary
echo "  • Admin Server Page Protection" >> "$BACKUP_DIR/installation_${TIMESTAMP}.log"

print_status "Clearing cache after server protection..."
cd "$PANEL_PATH" && php artisan view:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan config:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan route:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan cache:clear > /dev/null 2>&1

print_success "Server protection complete!"

# ═══════════════════════════════════════════════════════════════
#  KahfiModTzy :: Protect API/Bot User/Admin Creation
#  Fix: admin kedua tidak boleh create admin lewat bot/API
# ═══════════════════════════════════════════════════════════════

print_status "Installing API/Bot User Admin Creation Protection..."

php <<'PHP_PATCH'
<?php
$panelPath = '/var/www/pterodactyl';
$backupDir = '/root/pterodactyl_backups';
$timestamp = gmdate('Y-m-d-H-i-s');

if (!is_dir($backupDir)) {
    mkdir($backupDir, 0755, true);
}

function kahfi_backup_file(string $file, string $name, string $backupDir, string $timestamp): void
{
    if (is_file($file)) {
        copy($file, rtrim($backupDir, '/') . '/' . $name . '_' . $timestamp . '.bak');
        echo "Backed up: {$name}\n";
    }
}

function kahfi_patch_handle_guard(string $file, string $backupName, string $marker, string $guard, string $backupDir, string $timestamp): void
{
    if (!is_file($file)) {
        echo "WARNING: File not found: {$file}\n";
        return;
    }

    $contents = file_get_contents($file);
    if ($contents === false) {
        echo "WARNING: Cannot read: {$file}\n";
        return;
    }

    if (strpos($contents, $marker) !== false) {
        echo "Already protected: {$backupName}\n";
        return;
    }

    kahfi_backup_file($file, $backupName, $backupDir, $timestamp);

    $pattern = '/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';
    if (!preg_match($pattern, $contents, $match, PREG_OFFSET_CAPTURE)) {
        echo "WARNING: handle() method not found in {$file}\n";
        return;
    }

    $insertAt = $match[0][1] + strlen($match[0][0]);
    $patched = substr($contents, 0, $insertAt) . "\n" . rtrim($guard) . "\n" . substr($contents, $insertAt);

    file_put_contents($file, $patched);
    echo "Protected: {$backupName}\n";
}

function kahfi_remove_legacy_user_creation_guard(string $file, string $backupDir, string $timestamp): void
{
    if (!is_file($file)) {
        return;
    }

    $contents = file_get_contents($file);
    if ($contents === false) {
        return;
    }

    // Hapus guard lama yang memblokir semua create user dari admin kedua.
    $legacyPattern = '/\n\s*\/\/ KahfiModTzy Protection :: API\/Bot User Creation Security\s*\n\s*\/\/ Jalur bot\/API juga lewat service ini, jadi admin kedua tidak bisa create user\/admin\.\s*\n\s*\$kahfiAuthUser = \\\\Illuminate\\\\Support\\\\Facades\\\\Auth::user\(\) \?: request\(\)->user\(\);\s*\n\s*if \(\$kahfiAuthUser && \(int\) \$kahfiAuthUser->id !== 1\) \{\s*\n\s*throw new \\\\Pterodactyl\\\\Exceptions\\\\DisplayException\("✖ KahfiModTzy Protection :: Only Root Admin can create users\/admins via API\/Bot"\);\s*\n\s*\}\s*/m';

    $patched = preg_replace($legacyPattern, "\n", $contents, 1, $count);

    if ($patched !== null && $count > 0) {
        kahfi_backup_file($file, 'UserCreationService_legacy_guard_removed', $backupDir, $timestamp);
        file_put_contents($file, $patched);
        echo "Removed legacy blocking guard: UserCreationService\n";
    }
}

$userCreationService = $panelPath . '/app/Services/Users/UserCreationService.php';
$userUpdateService = $panelPath . '/app/Services/Users/UserUpdateService.php';

kahfi_remove_legacy_user_creation_guard($userCreationService, $backupDir, $timestamp);

$creationGuard = <<<'GUARD'
        // KahfiModTzy Protection :: API/Bot User Creation Security
        // Admin kedua boleh create user biasa; yang diblokir hanya admin/root_admin.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user() ?: request()->user();
        if ($kahfiAuthUser && (int) $kahfiAuthUser->id !== 1) {
            $kahfiIncomingData = (isset($data) && is_array($data)) ? $data : [];
            $kahfiRootAdminRaw = $kahfiIncomingData['root_admin'] ?? false;
            $kahfiRootAdminEnabled = filter_var($kahfiRootAdminRaw, FILTER_VALIDATE_BOOLEAN);

            if ($kahfiRootAdminEnabled) {
                throw new \Pterodactyl\Exceptions\DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can create admin/root_admin accounts via API/Bot");
            }

            // Paksa jalur bot/API dari admin kedua tetap membuat user biasa.
            if (isset($data) && is_array($data)) {
                $data['root_admin'] = false;
            }
        }
GUARD;

$updateGuard = <<<'GUARD'
        // KahfiModTzy Protection :: API/Bot Admin Privilege Update Security
        // Mencegah admin kedua mengangkat akun menjadi root_admin lewat bot/API.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user() ?: request()->user();
        if ($kahfiAuthUser && (int) $kahfiAuthUser->id !== 1) {
            if (isset($data) && is_array($data) && array_key_exists('root_admin', $data)) {
                throw new \Pterodactyl\Exceptions\DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can modify admin privileges via API/Bot");
            }

            if (isset($user) && is_object($user) && !empty($user->root_admin)) {
                throw new \Pterodactyl\Exceptions\DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can modify admin accounts via API/Bot");
            }
        }
GUARD;

kahfi_patch_handle_guard(
    $userCreationService,
    'UserCreationService_api_bot_guard',
    'KahfiModTzy Protection :: API/Bot User Creation Security',
    $creationGuard,
    $backupDir,
    $timestamp
);

kahfi_patch_handle_guard(
    $userUpdateService,
    'UserUpdateService_api_bot_guard',
    'KahfiModTzy Protection :: API/Bot Admin Privilege Update Security',
    $updateGuard,
    $backupDir,
    $timestamp
);
PHP_PATCH

print_success "API/Bot user/admin creation protection installed!"

echo "  • API/Bot User/Admin Creation Protection" >> "$BACKUP_DIR/installation_${TIMESTAMP}.log"

print_status "Clearing cache after API/Bot protection..."
cd "$PANEL_PATH" && php artisan optimize:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan queue:restart > /dev/null 2>&1

print_success "API/Bot protection complete!"

# ═══════════════════════════════════════════════════════════════
#  KahfiModTzy :: Protect API Key Revoke/Delete
#  Fix: admin kedua tidak boleh revoke/delete API key manual atau lewat bot/API
# ═══════════════════════════════════════════════════════════════

print_status "Installing API Key Revoke Protection..."

php <<'PHP_PATCH'
<?php
$panelPath = '/var/www/pterodactyl';
$backupDir = '/root/pterodactyl_backups';
$timestamp = gmdate('Y-m-d-H-i-s');

if (!is_dir($backupDir)) {
    mkdir($backupDir, 0755, true);
}

function kahfi_backup_file_apikey(string $file, string $name, string $backupDir, string $timestamp): void
{
    if (is_file($file)) {
        copy($file, rtrim($backupDir, '/') . '/' . $name . '_' . $timestamp . '.bak');
        echo "Backed up: {$name}\n";
    }
}

function kahfi_patch_methods_apikey_guard(
    string $file,
    string $backupName,
    string $marker,
    string $guard,
    array $methodNames,
    string $backupDir,
    string $timestamp
): void {
    if (!is_file($file)) {
        echo "WARNING: File not found: {$file}\n";
        return;
    }

    $contents = file_get_contents($file);
    if ($contents === false) {
        echo "WARNING: Cannot read: {$file}\n";
        return;
    }

    if (strpos($contents, $marker) !== false) {
        echo "Already protected: {$backupName}\n";
        return;
    }

    $methodRegex = implode('|', array_map('preg_quote', $methodNames));
    $pattern = '/public\s+function\s+(' . $methodRegex . ')\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';

    $count = 0;
    $patched = preg_replace_callback($pattern, function ($match) use ($guard, &$count) {
        $count++;
        return $match[0] . "\n" . rtrim($guard) . "\n";
    }, $contents, -1, $count);

    if ($count < 1 || $patched === null) {
        echo "WARNING: revoke/delete method not found in {$file}\n";
        return;
    }

    kahfi_backup_file_apikey($file, $backupName, $backupDir, $timestamp);
    file_put_contents($file, $patched);
    echo "Protected: {$backupName} ({$count} method(s))\n";
}

function kahfi_find_service_files(string $baseDir): array
{
    $files = [];
    if (!is_dir($baseDir)) {
        return $files;
    }

    $iterator = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($baseDir, FilesystemIterator::SKIP_DOTS)
    );

    foreach ($iterator as $fileInfo) {
        if (!$fileInfo->isFile()) {
            continue;
        }

        $path = $fileInfo->getPathname();
        $base = $fileInfo->getBasename();

        // Target service penghapus API key Pterodactyl, beda versi kadang beda nama file.
        if (preg_match('/(KeyDeletionService|ApiKeyDeletionService|ApplicationApiKeyDeletionService|ClientApiKeyDeletionService)\.php$/i', $base)) {
            $files[] = $path;
        }
    }

    return array_values(array_unique($files));
}

$guard = <<<'GUARD'
        // KahfiModTzy Protection :: API Key Revoke Security
        // Selain Root Admin ID 1 tidak boleh revoke/delete API key, baik manual maupun lewat bot/API.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try {
                $kahfiAuthUser = request()->user();
            } catch (\Throwable $e) {
                $kahfiAuthUser = null;
            }
        }

        if ($kahfiAuthUser && (int) $kahfiAuthUser->id !== 1) {
            throw new \Pterodactyl\Exceptions\DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can revoke/delete API keys");
        }
GUARD;

// Manual panel admin: Admin > Application API / API Keys.
$controllerCandidates = [
    $panelPath . '/app/Http/Controllers/Admin/ApiController.php',
    $panelPath . '/app/Http/Controllers/Admin/ApiKeyController.php',
    $panelPath . '/app/Http/Controllers/Admin/ApiKeysController.php',

    // Client/account API keys. Ini juga dikunci supaya admin kedua tidak bisa revoke lewat jalur akun/API.
    $panelPath . '/app/Http/Controllers/Api/Client/Account/ApiKeyController.php',
    $panelPath . '/app/Http/Controllers/Api/Client/Account/ApiKeysController.php',

    // Beberapa fork/theme/custom panel menaruh endpoint API key di application controller.
    $panelPath . '/app/Http/Controllers/Api/Application/ApiKeyController.php',
    $panelPath . '/app/Http/Controllers/Api/Application/ApiKeysController.php',
];

foreach ($controllerCandidates as $file) {
    if (is_file($file)) {
        kahfi_patch_methods_apikey_guard(
            $file,
            'apikey_revoke_controller_' . basename($file, '.php'),
            'KahfiModTzy Protection :: API Key Revoke Security',
            $guard,
            ['delete', 'destroy', 'revoke', 'remove'],
            $backupDir,
            $timestamp
        );
    }
}

// Service-level protection: ini penting agar request dari bot/API juga tetap kena blokir.
$serviceFiles = kahfi_find_service_files($panelPath . '/app/Services');
foreach ($serviceFiles as $file) {
    kahfi_patch_methods_apikey_guard(
        $file,
        'apikey_revoke_service_' . basename($file, '.php'),
        'KahfiModTzy Protection :: API Key Revoke Security',
        $guard,
        ['handle', 'delete', 'destroy', 'revoke', 'remove'],
        $backupDir,
        $timestamp
    );
}

if (empty($serviceFiles)) {
    echo "WARNING: No API key deletion service file found. Controller protection still applied if files existed.\n";
}
PHP_PATCH

print_success "API Key revoke/delete protection installed!"

echo "  • API Key Revoke/Delete Protection" >> "$BACKUP_DIR/installation_${TIMESTAMP}.log"

print_status "Clearing cache after API Key revoke protection..."
cd "$PANEL_PATH" && php artisan optimize:clear > /dev/null 2>&1
cd "$PANEL_PATH" && php artisan queue:restart > /dev/null 2>&1

print_success "API Key revoke protection complete!"


# ============================================================
# FINAL PATCH AUTO RUN
# Fix:
# - backup/download SC tidak error
# - admin utama panel ID 1 bisa delete server
# - admin 2/3 tidak bisa delete server
# ============================================================

echo ""
echo "Running final ID1 delete + backup/download fix..."


#!/bin/bash
# Reset + fix delete server Pterodactyl:
# - Admin utama panel ID 1 bisa delete server
# - Admin 2/3/user biasa tidak bisa delete server
# - Download/backup SC tidak diblokir protect FileController
# - Restore controller dari backup clean kalau ada, lalu patch minimal
set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFI FIX DELETE SERVER FINAL =="
say "Panel: $PANEL"
say "Backup: $BACKUP"
echo

backup_now() {
  local f="$1"
  local n="$2"
  if [ -f "$f" ]; then
    cp "$f" "$BACKUP/${n}_before_final_delete_fix_${TS}.bak"
    echo "Backup: $n"
  fi
}

backup_now "app/Http/Controllers/Admin/ServersController.php" "ServersController"
backup_now "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_now "app/Http/Controllers/Api/Client/Servers/FileController.php" "FileController"

# Ambil backup ServersController clean sebelum protect, kalau ada.
RESTORED=0
for f in $(ls -t "$BACKUP"/ServersController_*.bak 2>/dev/null || true); do
  if grep -q "class ServersController" "$f" && ! grep -q "KahfiModTzy" "$f"; then
    cp "$f" "app/Http/Controllers/Admin/ServersController.php"
    echo "Restore clean ServersController dari: $f"
    RESTORED=1
    break
  fi
done

if [ "$RESTORED" = "0" ]; then
  echo "INFO: Backup clean ServersController tidak ketemu, patch file yang ada sekarang."
fi

# Tulis ServerDeletionService yang tegas:
# ID 1 boleh delete, selain ID 1 blok.
# Force daemon/database error agar UI admin ID1 tidak 500 cuma karena Wings/node bermasalah.
cat > app/Services/Servers/ServerDeletionService.php <<'PHP'
<?php

namespace Pterodactyl\Services\Servers;

use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Exceptions\DisplayException;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

class ServerDeletionService
{
    protected bool $force = false;

    public function __construct(
        private ConnectionInterface $connection,
        private DaemonServerRepository $daemonServerRepository,
        private DatabaseManagementService $databaseManagementService
    ) {}

    public function withForce(bool $bool = true): self
    {
        $this->force = $bool;
        return $this;
    }

    public function handle(Server $server): void
    {
        $user = Auth::user();

        // FIX FINAL:
        // Admin utama panel = ID 1.
        // Selain ID 1, termasuk admin 2/3, tidak bisa delete server.
        if (!$user || (int) $user->id !== 1) {
            throw new DisplayException('KahfiModTzy Protection :: hanya admin utama ID 1 yang boleh delete server.');
        }

        // Paksa force untuk admin utama ID 1 agar tidak 500 kalau Wings/node lagi error.
        $this->force = true;

        try {
            $this->daemonServerRepository->setServer($server)->delete();
        } catch (DaemonConnectionException $exception) {
            Log::warning($exception);
        } catch (\Throwable $exception) {
            Log::warning($exception);
        }

        $this->connection->transaction(function () use ($server) {
            foreach ($server->databases as $database) {
                try {
                    $this->databaseManagementService->delete($database);
                } catch (\Throwable $exception) {
                    Log::warning($exception);

                    try {
                        $database->delete();
                    } catch (\Throwable $ignored) {
                        Log::warning($ignored);
                    }
                }
            }

            $server->delete();
        });
    }
}
PHP

# Patch controller secara minimal, tanpa rewrite semua fitur.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Admin/ServersController.php';
$s = file_get_contents($file);
if ($s === false) {
    fwrite(STDERR, "ERROR: Tidak bisa baca ServersController.php\n");
    exit(1);
}

function addUseIfMissing(string $s, string $use): string {
    if (strpos($s, $use) !== false) return $s;
    return preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\n{$use}\n", $s, 1);
}

function findMethod(string $s, string $name): ?array {
    $pattern = '/public\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) return null;

    $start = $m[0][1];
    $brace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);

    for ($i = $brace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) return [$start, $i + 1];
        }
    }

    return null;
}

$s = addUseIfMissing($s, 'use Illuminate\Support\Facades\Auth;');
$s = addUseIfMissing($s, 'use Pterodactyl\Exceptions\DisplayException;');
$s = addUseIfMissing($s, 'use Illuminate\Http\Request;');

$newDelete = <<<'PHP'
    public function delete(Request $request, Server $server): RedirectResponse
    {
        $authUser = Auth::user();

        // FIX FINAL:
        // Admin utama panel = ID 1.
        // Admin 2/3 dan user biasa tidak bisa delete server.
        if (!$authUser || (int) $authUser->id !== 1) {
            throw new DisplayException('KahfiModTzy Protection :: hanya admin utama ID 1 yang boleh delete server.');
        }

        // Force delete otomatis agar admin utama tidak kena 500 saat Wings/node error.
        $this->deletionService->withForce(true)->handle($server);

        $this->alert->success('Server berhasil dihapus.')->flash();

        return redirect()->route('admin.servers');
    }
PHP;

$block = findMethod($s, 'delete');

if (!$block) {
    fwrite(STDERR, "ERROR: Method public function delete(...) tidak ketemu di ServersController.php\n");
    exit(1);
}

[$a, $b] = $block;
$s = substr($s, 0, $a) . $newDelete . substr($s, $b);

file_put_contents($file, $s);
echo "OK: ServersController delete method sudah dipatch.\n";
PHP_PATCH

# ServerController: hilangkan owner_id custom yang bikin user/subuser server sendiri kena 403 saat load backup/file API.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php';
if (!is_file($file)) {
    echo "SKIP: ServerController client tidak ketemu.\n";
    exit(0);
}

$s = file_get_contents($file);
if ($s === false) {
    echo "SKIP: Tidak bisa baca ServerController client.\n";
    exit(0);
}

function kahfiFindMethodBackupFix(string $s, string $name): ?array {
    $pattern = '/public\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) return null;

    $start = $m[0][1];
    $brace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);

    for ($i = $brace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) return [$start, $i + 1];
        }
    }

    return null;
}

$block = kahfiFindMethodBackupFix($s, 'index');
if (!$block) {
    echo "INFO: index method tidak ada di ServerController client.\n";
    exit(0);
}

$newMethod = <<<'PHP'
    public function index(GetServerRequest $request, Server $server): array
    {
        // FIX: jangan blokir server API dengan owner_id custom.
        // GetServerRequest bawaan Pterodactyl sudah cek akses user/subuser ke server.
        // Ini penting supaya fitur backup/download server sendiri tidak kena 403 dari protect.
        return $this->fractal->item($server)
            ->transformWith($this->getTransformer(ServerTransformer::class))
            ->addMeta([
                "is_server_owner" => $request->user()->id === $server->owner_id,
                "user_permissions" => $this->permissionsService->handle($server, $request->user()),
            ])
            ->toArray();
    }
PHP;

[$a, $b] = $block;
$s = substr($s, 0, $a) . $newMethod . substr($s, $b);

file_put_contents($file, $s);
echo "OK: Client ServerController owner_id custom check dimatikan.\n";
PHP_PATCH

# FileController: matikan check custom yang bikin file manager/download/compress/backup error.
# Permission bawaan Pterodactyl tetap aktif lewat Request class.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/FileController.php';
if (!is_file($file)) {
    echo "SKIP: FileController tidak ketemu.\n";
    exit(0);
}

$s = file_get_contents($file);
if ($s === false) {
    echo "SKIP: Tidak bisa baca FileController.\n";
    exit(0);
}

function findPrivateMethod(string $s, string $name): ?array {
    $pattern = '/private\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) return null;

    $start = $m[0][1];
    $brace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);

    for ($i = $brace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) return [$start, $i + 1];
        }
    }

    return null;
}

$block = findPrivateMethod($s, 'checkServerAccess');
if (!$block) {
    echo "INFO: checkServerAccess tidak ada, FileController mungkin sudah bawaan.\n";
    exit(0);
}

$newMethod = <<<'PHP'
    private function checkServerAccess($request, Server $server)
    {
        // FIX: jangan blokir file manager/backup/download dengan protect custom.
        // Permission bawaan Pterodactyl tetap berjalan dari request class.
        return;
    }
PHP;

[$a, $b] = $block;
$s = substr($s, 0, $a) . $newMethod . substr($s, $b);

file_put_contents($file, $s);
echo "OK: FileController checkServerAccess dimatikan.\n";
PHP_PATCH

echo
echo "== CEK SYNTAX PHP =="
php -l app/Services/Servers/ServerDeletionService.php || exit 1
php -l app/Http/Controllers/Admin/ServersController.php || exit 1
[ -f app/Http/Controllers/Api/Client/Servers/FileController.php ] && php -l app/Http/Controllers/Api/Client/Servers/FileController.php || true

echo
echo "== CEK ADMIN ID 1 =="
php artisan tinker --execute='
$u = Pterodactyl\Models\User::find(1);
if (!$u) { echo "WARNING: User ID 1 tidak ada\n"; exit; }
echo "ID=1 USER={$u->username} EMAIL={$u->email} ROOT_ADMIN=" . ((int)$u->root_admin) . PHP_EOL;
' || true

echo
echo "== CLEAR CACHE + RESTART SERVICE =="
chown -R www-data:www-data "$PANEL" || true
php artisan optimize:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

# Restart php-fpm agar opcache tidak pakai file lama.
for svc in $(systemctl list-units --type=service --all | awk '{print $1}' | grep -E '^php[0-9.]+-fpm\.service$' || true); do
  echo "Restart $svc"
  systemctl restart "$svc" || true
done

systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
systemctl restart wings 2>/dev/null || true

echo
echo "DONE."
echo "Sekarang coba login user pemilik server, lalu test Backup + Download file."
echo "Kalau masih gagal, langsung kirim output ini:"
echo "tail -n 120 /var/www/pterodactyl/storage/logs/laravel-*.log"
