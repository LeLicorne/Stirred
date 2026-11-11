/* DXMT (Metal Direct3D 11) needs these entry points exported from winemac.so; this one returns the view to render into. */
__attribute__((visibility("default")))
WineContentView *macdrv_get_client_cocoa_view(HWND hwnd)
{
    struct macdrv_win_data *data;
    WineContentView *view = NULL;

    if (!(data = get_win_data(hwnd))) return NULL;
    if (!(view = data->client_view))
    {
        view = macdrv_create_view(cgrect_from_rect(data->rects.client));
        macdrv_set_view_superview(view, NULL, data->cocoa_window, NULL, NULL);
        macdrv_set_view_hidden(view, FALSE);
        data->client_view = view;
        data->dxmt_view = 1;
    }
    release_win_data(data);
    return view;
}


/* Layout DXMT expects for the window data (CrossOver's), followed by what is needed to give the real data back. */
struct dxmt_win_data
{
    HWND                hwnd;
    WineWindow         *cocoa_window;
    WineContentView    *cocoa_view;
    WineContentView    *client_cocoa_view;
    struct macdrv_win_data *real;
};

static struct dxmt_win_data *dxmt_get_win_data(HWND hwnd)
{
    struct dxmt_win_data *compat = calloc(1, sizeof(*compat));
    struct macdrv_win_data *data;

    if (!compat) return NULL;
    compat->hwnd = hwnd;
    if (!(data = get_win_data(hwnd))) return compat;
    compat->real = data;
    compat->cocoa_window = data->cocoa_window;
    if (!(compat->client_cocoa_view = data->client_view))
    {
        compat->client_cocoa_view = macdrv_create_view(cgrect_from_rect(data->rects.client));
        macdrv_set_view_superview(compat->client_cocoa_view, NULL, data->cocoa_window, NULL, NULL);
        macdrv_set_view_hidden(compat->client_cocoa_view, FALSE);
        data->client_view = compat->client_cocoa_view;
        data->dxmt_view = 1;
    }
    return compat;
}

static void dxmt_release_win_data(struct dxmt_win_data *compat)
{
    if (!compat) return;
    if (compat->real) release_win_data(compat->real);
    free(compat);
}

struct dxmt_macdrv_functions
{
    void (*macdrv_init_display_devices)(BOOL);
    struct dxmt_win_data *(*get_win_data)(HWND hwnd);
    void (*release_win_data)(struct dxmt_win_data *data);
    WineWindow *(*macdrv_get_cocoa_window)(HWND hwnd, BOOL require_on_screen);
    void *(*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(void *device);
    void *(*macdrv_view_create_metal_view)(void *view, void *device);
    void *(*macdrv_view_get_metal_layer)(void *view);
    void (*macdrv_view_release_metal_view)(void *view);
    void *on_main_thread;
};

__attribute__((visibility("default")))
struct dxmt_macdrv_functions macdrv_functions =
{
    NULL,
    dxmt_get_win_data,
    dxmt_release_win_data,
    (void *)macdrv_get_cocoa_window,
    (void *)macdrv_create_metal_device,
    (void *)macdrv_release_metal_device,
    (void *)macdrv_view_create_metal_view,
    (void *)macdrv_view_get_metal_layer,
    (void *)macdrv_view_release_metal_view,
    NULL,
};
