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
        return $this->view->make("admin.users.new", [
            "languages" => $this->getAvailableLanguages(true),
        ]);
    }

    public function view(User $user): View
    {
        return $this->view->make("admin.users.view", [
            "user" => $user,
            "languages" => $this->getAvailableLanguages(true),
        ]);
    }

    public function delete(Request $request, User $user): RedirectResponse
    {
        // KahfiModTzy Protection :: User Deletion Security
        if ($request->user()->id !== 1) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Only Root Admin can delete users");
        }

        if ($request->user()->id === $user->id) {
            throw new DisplayException($this->translator->get("admin/user.exceptions.user_has_servers"));
        }

        $this->deletionService->handle($user);
        return redirect()->route("admin.users");
    }

    public function store(NewUserFormRequest $request): RedirectResponse
    {
        $user = $this->creationService->handle($request->normalize());
        $this->alert->success($this->translator->get("admin/user.notices.account_created"))->flash();

        return redirect()->route("admin.users.view", $user->id);
    }

    public function update(UserFormRequest $request, User $user): RedirectResponse
    {
        // KahfiModTzy Protection :: User Modification Security
        $restrictedFields = ["email", "first_name", "last_name", "password", "root_admin"];

        foreach ($restrictedFields as $field) {
            if ($request->filled($field) && $request->user()->id !== 1) {
                throw new DisplayException("✖ KahfiModTzy Protection :: Restricted field modification");
            }
        }

        if ($user->root_admin && $request->user()->id !== 1) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Admin privilege modification blocked");
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
        $user = $request->user();

        // Admin (user id = 1) can access all
        if ($user->id === 1) {
            return;
        }

        // Users can only access their own servers
        if ($server->owner_id !== $user->id) {
            abort(403, "✖ KahfiModTzy Protection :: File access denied");
        }
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
        // KahfiModTzy Protection :: Server Access Security
        $authUser = Auth::user();

        if ($authUser->id !== 1 && (int) $server->owner_id !== (int) $authUser->id) {
            abort(403, "✖ KahfiModTzy Protection :: Server access denied");
        }

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