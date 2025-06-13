.class Lcom/oneplus/plugin/OpLsState$1;
.super Lcom/android/keyguard/KeyguardUpdateMonitorCallback;
.source "OpLsState.java"


# annotations
.annotation system Ldalvik/annotation/EnclosingClass;
    value = Lcom/oneplus/plugin/OpLsState;
.end annotation

.annotation system Ldalvik/annotation/InnerClass;
    accessFlags = 0x0
    name = null
.end annotation


# instance fields
.field final synthetic this$0:Lcom/oneplus/plugin/OpLsState;


# direct methods
.method constructor <init>(Lcom/oneplus/plugin/OpLsState;)V
    .registers 2

    .line 125
    iput-object p1, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    invoke-direct {p0}, Lcom/android/keyguard/KeyguardUpdateMonitorCallback;-><init>()V

    return-void
.end method


# virtual methods
.method public onFinishedGoingToSleep(I)V
    .registers 6

    .line 150
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    const/4 v1, 0x0

    :goto_6
    if-ge v1, v0, :cond_18

    aget-object v2, p0, v1

    if-eqz v2, :cond_15

    .line 151
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_15

    .line 152
    invoke-virtual {v2, p1}, Lcom/oneplus/plugin/OpBaseCtrl;->onFinishedGoingToSleep(I)V

    :cond_15
    add-int/lit8 v1, v1, 0x1

    goto :goto_6

    :cond_18
    return-void
.end method

.method public onKeyguardBouncerChanged(Z)V
    .registers 6

    .line 169
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    const/4 v1, 0x0

    :goto_6
    if-ge v1, v0, :cond_18

    aget-object v2, p0, v1

    if-eqz v2, :cond_15

    .line 170
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_15

    .line 171
    invoke-virtual {v2, p1}, Lcom/oneplus/plugin/OpBaseCtrl;->onKeyguardBouncerChanged(Z)V

    :cond_15
    add-int/lit8 v1, v1, 0x1

    goto :goto_6

    :cond_18
    return-void
.end method

.method public onKeyguardVisibilityChanged(Z)V
    .registers 6

    .line 178
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    const/4 v1, 0x0

    :goto_6
    if-ge v1, v0, :cond_18

    aget-object v2, p0, v1

    if-eqz v2, :cond_15

    .line 179
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_15

    .line 180
    invoke-virtual {v2, p1}, Lcom/oneplus/plugin/OpBaseCtrl;->onKeyguardVisibilityChanged(Z)V

    :cond_15
    add-int/lit8 v1, v1, 0x1

    goto :goto_6

    :cond_18
    return-void
.end method

.method public onScreenTurnedOff()V
    .registers 5

    .line 159
    iget-object v0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    const/4 v1, 0x0

    invoke-static {v0, v1}, Lcom/oneplus/plugin/OpLsState;->access$102(Lcom/oneplus/plugin/OpLsState;Z)Z

    .line 160
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    :goto_b
    if-ge v1, v0, :cond_1d

    aget-object v2, p0, v1

    if-eqz v2, :cond_1a

    .line 161
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_1a

    .line 162
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->onScreenTurnedOff()V

    :cond_1a
    add-int/lit8 v1, v1, 0x1

    goto :goto_b

    :cond_1d
    return-void
.end method

.method public onStartedGoingToSleep(I)V
    .registers 6

    .line 139
    iget-object v0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    const/4 v1, 0x0

    invoke-static {v0, v1}, Lcom/oneplus/plugin/OpLsState;->access$102(Lcom/oneplus/plugin/OpLsState;Z)Z

    .line 141
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    :goto_b
    if-ge v1, v0, :cond_1d

    aget-object v2, p0, v1

    if-eqz v2, :cond_1a

    .line 142
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_1a

    .line 143
    invoke-virtual {v2, p1}, Lcom/oneplus/plugin/OpBaseCtrl;->onStartedGoingToSleep(I)V

    :cond_1a
    add-int/lit8 v1, v1, 0x1

    goto :goto_b

    :cond_1d
    return-void
.end method

.method public onStartedWakingUp()V
    .registers 5

    .line 128
    iget-object v0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    const/4 v1, 0x1

    invoke-static {v0, v1}, Lcom/oneplus/plugin/OpLsState;->access$102(Lcom/oneplus/plugin/OpLsState;Z)Z

    .line 130
    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState$1;->this$0:Lcom/oneplus/plugin/OpLsState;

    iget-object p0, p0, Lcom/oneplus/plugin/OpLsState;->mControls:[Lcom/oneplus/plugin/OpBaseCtrl;

    array-length v0, p0

    const/4 v1, 0x0

    :goto_c
    if-ge v1, v0, :cond_1e

    aget-object v2, p0, v1

    if-eqz v2, :cond_1b

    .line 131
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->isEnable()Z

    move-result v3

    if-eqz v3, :cond_1b

    .line 132
    invoke-virtual {v2}, Lcom/oneplus/plugin/OpBaseCtrl;->onStartedWakingUp()V

    :cond_1b
    add-int/lit8 v1, v1, 0x1

    goto :goto_c

    :cond_1e
    return-void
.end method
