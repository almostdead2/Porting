.class Lcom/oneplus/plugin/OpLsState$MyUIHandler;
.super Landroid/os/Handler;
.source "OpLsState.java"


# annotations
.annotation system Ldalvik/annotation/EnclosingClass;
    value = Lcom/oneplus/plugin/OpLsState;
.end annotation

.annotation system Ldalvik/annotation/InnerClass;
    accessFlags = 0x2
    name = "MyUIHandler"
.end annotation


# instance fields
.field final synthetic this$0:Lcom/oneplus/plugin/OpLsState;


# direct methods
.method private constructor <init>(Lcom/oneplus/plugin/OpLsState;)V
    .registers 2

    .line 312
    iput-object p1, p0, Lcom/oneplus/plugin/OpLsState$MyUIHandler;->this$0:Lcom/oneplus/plugin/OpLsState;

    invoke-direct {p0}, Landroid/os/Handler;-><init>()V

    return-void
.end method

.method synthetic constructor <init>(Lcom/oneplus/plugin/OpLsState;Lcom/oneplus/plugin/OpLsState$1;)V
    .registers 3

    .line 312
    invoke-direct {p0, p1}, Lcom/oneplus/plugin/OpLsState$MyUIHandler;-><init>(Lcom/oneplus/plugin/OpLsState;)V

    return-void
.end method


# virtual methods
.method public handleMessage(Landroid/os/Message;)V
    .registers 3

    .line 314
    iget p1, p1, Landroid/os/Message;->what:I

    const/4 v0, 0x1

    if-eq p1, v0, :cond_6

    goto :goto_a

    .line 317
    :cond_6
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$MyUIHandler;->this$0:Lcom/oneplus/plugin/OpLsState;

    monitor-enter p0

    .line 318
    :try_start_9
    monitor-exit p0

    :goto_a
    return-void

    :catchall_b
    move-exception p1

    monitor-exit p0
    :try_end_d
    .catchall {:try_start_9 .. :try_end_d} :catchall_b

    throw p1
.end method
