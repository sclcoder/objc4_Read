STK.register("kit.extra.language", function($) {
    window.$LANG || (window.$LANG = {});
    return function(temp, data) {
        var str = $.core.util.language(temp, $LANG);
        str = str.replace(/\\}/ig, "}");
        if (data) {
            str = $.templet(str, data);
        }
        return str;
    };
});;


if (typeof scope === "undefined") {
    scope = {};
}

scope.loginKit = function() {
    if (window.scope) {
        var uid = window.scope.current_user_weibo || window.scope.current_user_sina;
        if (uid) return {
            uid: uid,
            isLogin: !!uid
        };
    }
    if (window.$CONFIG) {
        var uid = window.$CONFIG.current_user_weibo || window.$CONFIG.current_user_sina || window.$CONFIG.uid || window.$CONFIG.$uid;
        if (uid) return {
            uid: uid,
            isLogin: !!uid
        };
    }
    var documentCookie = document.cookie + ";";
    var supRegExp = [ "SUP", "=([^;]*)?;" ].join("");
    var uidRegExp = [ "(\\?|&)", "uid", "=([^&]*)(&|$)" ].join("");
    var info = documentCookie.match(new RegExp(supRegExp, "i"));
    info = info ? info[1] || "" : "";
    info = unescape(info);
    var uid = info.match(new RegExp(uidRegExp));
    uid = uid ? uid[2] || "" : "";
    var oid = scope["$oid"];
    return {
        uid: uid,
        isLogin: !!uid,
        isAdmin: uid && oid && uid == oid
    };
};

scope.$isLogin = function() {
    return scope.loginKit().isLogin;
};

scope.$isAdmin = function() {
    return scope.loginKit().isAdmin;
};;




STK.register("core.obj.parseParam", function($) {
    return function(oSource, oParams, isown) {
        var key, obj = {};
        oParams = oParams || {};
        for (key in oSource) {
            obj[key] = oSource[key];
            if (oParams[key] != null) {
                if (isown) {
                    if (oSource.hasOwnProperty[key]) {
                        obj[key] = oParams[key];
                    }
                } else {
                    obj[key] = oParams[key];
                }
            }
        }
        return obj;
    };
});;


STK.register("common.widget.log", function($) {
    var CATEGARY = {
        app_sharebutton: 1,
        app_followbutton: 2,
        app_livestream: 4,
        app_listweibo: 5,
        app_weiboshow: 6,
        app_commentbox: 7
    };
    return function(opts) {
        var conf = $.core.obj.parseParam({
            vsrc: "app_weiboshow",
            refer: "",
            step: 1
        }, opts);
        var refer = scope.refer || scope.$refer || conf["refer"], uid = scope.loginKit().uid || "", appid = scope.appkey || $CONFIG.$appkey || $CONFIG.appkey || 0, cat = CATEGARY[conf.vsrc] || "";
        var src = "//rs.sinajs.cn/r.gif?uid=" + uid + "&appid=" + appid + "&refer=" + refer + "&cat=" + cat + "&step=" + conf["step"] + "&rnd=" + +(new Date);
        var img = new Image;
        img.src = src;
        img = null;
    };
});;


STK.register("common.widget.login", function($) {
    var args = {
        vsrc: "app_weiboshow",
        appsrc: "",
        showlogo: 0,
        callback: function() {}
    };
    var protocol = window.location.protocol == "https:" ? "https:" : "http:";
    if (typeof App === "undefined") {
        App = {};
    }
    return function(opts) {
        opts = $.parseParam(args, opts);
        if (!opts.appsrc) {
            opts.appsrc = scope ? scope.appsrc ? scope.appsrc : scope.$appsrc ? scope.$appsrc : "" : "";
        }
        var that = {};
        App.loginBackUrlCallBack = function(obj) {
            $.custEvent.fire(that, "login", obj);
            opts.step = 2;
            $.common.widget.log(opts);
        };
        var init = function() {
            parseDOM();
            bindDOM();
            bindCustEvt();
            bindListener();
        };
        var parseDOM = function() {};
        var bindDOM = function() {};
        var bindCustEvt = function() {
            $.custEvent.define(that, "login");
        };
        var bindListener = function() {
            $.custEvent.add(that, "login", function(obj) {
                opts.callback(obj);
            });
        };
        that.showLogin = function() {
            var params = "&" + $.jsonToQuery(opts);
            var is360 = navigator.userAgent.indexOf("360 Aphone Browser") >= 0;
            var isWeixin = /micromessenger\/(\d+\.\d+\.\d+)/i.test(navigator.userAgent);
            if (is360 || isWeixin) {
                location.href = protocol + "//service.weibo.com/reg/loginindex.php?regbackurl=http%3A%2F%2Fweibo.com&backurl=" + encodeURIComponent(location.href) + params + "&rnd=" + +(new Date).valueOf();
                return;
            }
            var weiboURL = protocol + "//service.weibo.com/reg/loginindex.php?regbackurl=http%3A%2F%2Fweibo.com&backurl=http%3A%2F%2F" + location.host + "%2Fstaticjs%2FloginProxy.html" + params + "&rnd=" + +(new Date).valueOf();
            if (/weibo.com/.test(location.host)) {
                weiboURL = weiboURL.replace(/\/widget/, "");
            }
            var loginPopWindow = window.open(weiboURL, "miniblog_login", [ "toolbar=1,status=0,resizable=1,width=620,height=540,left=", (screen.width - 620) / 2, ",top=", (screen.height - 450) / 2 ].join(""));
            loginPopWindow.focus();
            $.common.widget.log(opts);
        };
        init();
        return that;
    };
});;






STK.register("module.layer", function($) {
    var getSize = function(box) {
        var ret = {};
        if (box.style.display == "none") {
            box.style.visibility = "hidden";
            box.style.display = "";
            ret.w = box.offsetWidth;
            ret.h = box.offsetHeight;
            box.style.display = "none";
            box.style.visibility = "visible";
        } else {
            ret.w = box.offsetWidth;
            ret.h = box.offsetHeight;
        }
        return ret;
    };
    var getPosition = function(el, key) {
        key = key || "topleft";
        var posi = null;
        if (el.style.display == "none") {
            el.style.visibility = "hidden";
            el.style.display = "";
            posi = $.core.dom.position(el);
            el.style.display = "none";
            el.style.visibility = "visible";
        } else {
            posi = $.core.dom.position(el);
        }
        if (key !== "topleft") {
            var size = getSize(el);
            if (key === "topright") {
                posi["l"] = posi["l"] + size["w"];
            } else if (key === "bottomleft") {
                posi["t"] = posi["t"] + size["h"];
            } else if (key === "bottomright") {
                posi["l"] = posi["l"] + size["w"];
                posi["t"] = posi["t"] + size["h"];
            }
        }
        return posi;
    };
    return function(template) {
        var dom = $.core.dom.builder(template);
        var outer = dom.list["outer"][0], inner = dom.list["inner"][0];
        var uniqueID = $.core.dom.uniqueID(outer);
        var that = {};
        var custKey = $.core.evt.custEvent.define(that, "show");
        $.core.evt.custEvent.define(custKey, "hide");
        var sizeCache = null;
        that.show = function() {
            outer.style.display = "";
            $.core.evt.custEvent.fire(custKey, "show");
            return that;
        };
        that.hide = function() {
            outer.style.display = "none";
            $.custEvent.fire(custKey, "hide");
            return that;
        };
        that.getPosition = function(key) {
            return getPosition(outer, key);
        };
        that.getSize = function(isFlash) {
            if (isFlash || !sizeCache) {
                sizeCache = getSize.apply(that, [ outer ]);
            }
            return sizeCache;
        };
        that.html = function(html) {
            if (html !== undefined) {
                inner.innerHTML = html;
            }
            return inner.innerHTML;
        };
        that.text = function(str) {
            if (text !== undefined) {
                inner.innerHTML = $.core.str.encodeHTML(str);
            }
            return $.core.str.decodeHTML(inner.innerHTML);
        };
        that.appendChild = function(node) {
            inner.appendChild(node);
            return that;
        };
        that.getUniqueID = function() {
            return uniqueID;
        };
        that.getOuter = function() {
            return outer;
        };
        that.getInner = function() {
            return inner;
        };
        that.getParentNode = function() {
            return outer.parentNode;
        };
        that.getDomList = function() {
            return dom.list;
        };
        that.getDomListByKey = function(key) {
            return dom.list[key];
        };
        that.getDom = function(key, index) {
            if (!dom.list[key]) {
                return false;
            }
            return dom.list[key][index || 0];
        };
        that.getCascadeDom = function(key, index) {
            if (!dom.list[key]) {
                return false;
            }
            return $.core.dom.cascadeNode(dom.list[key][index || 0]);
        };
        return that;
    };
});;


STK.register("ui.tipPrototype", function($) {
    var zIndex = 10003;
    return function(spec) {
        var conf, tipPrototype, box, content, tipWH;
        var template = '<div node-type="outer" class="WB_widgets W_layer" style="position: absolute; display:none;" >' + '<div node-type="inner" class="bg"></div>' + "</div>";
        conf = $.parseParam({
            direct: "up",
            showCallback: $.core.func.empty,
            hideCallback: $.core.func.empty
        }, spec);
        tipPrototype = $.module.layer(template, conf);
        box = tipPrototype.getOuter();
        content = tipPrototype.getInner();
        tipPrototype.setTipWH = function() {
            tipWH = this.getSize(true);
            this.tipWidth = tipWH.w;
            this.tipHeight = tipWH.h;
            return this;
        };
        tipPrototype.setTipWH();
        tipPrototype.setContent = function(cont) {
            if (typeof cont == "string") {
                content.innerHTML = cont;
            } else {
                content.appendChild(cont);
            }
            this.setTipWH();
            return this;
        };
        tipPrototype.setLayerXY = function(pNode) {
            if (!pNode) {
                throw "ui.tipPrototype need pNode as first parameter to set tip position";
            }
            var pNodePosition = STK.core.dom.position(pNode);
            var pNodePositionLeft = pNodePosition.l;
            var pNodeWidth = pNode.offsetWidth;
            var pNodeHeight = pNode.offsetHeight;
            var tipPositionLeft = Math.min(Math.max(pNodePositionLeft + (pNodeWidth - this.tipWidth) / 2, $.scrollPos().left), $.scrollPos().left + STK.winSize().width - this.tipWidth);
            var tipPositionTop = pNodePosition.t;
            if (conf.direct === "down") {
                tipPositionTop += pNodeHeight;
            }
            var arr = [ ";" ];
            arr.push("z-index:", zIndex++, ";");
            arr.push("width:", this.tipWidth, "px;");
            arr.push("height:", this.tipHeight, "px;");
            arr.push("top:", tipPositionTop, "px;");
            arr.push("left:", tipPositionLeft, "px;");
            box.style.cssText += arr.join("");
        };
        tipPrototype.aniShow = function() {
            var outer = this.getOuter();
            outer.style.height = "0px";
            outer.style.display = "";
            var ani = $.core.ani.tween(outer, {
                end: conf.showCallback,
                duration: 250,
                animationType: "easeoutcubic"
            });
            if (conf.direct === "down") {
                ani.play({
                    height: this.tipHeight
                }, {
                    staticStyle: "overflow:hidden;position:absolute;"
                });
            } else {
                var top = parseInt(outer.style.top, 10) - this.tipHeight;
                ani.play({
                    height: this.tipHeight,
                    top: Math.max(top, $.scrollPos().top)
                }, {
                    staticStyle: "overflow:hidden;position:absolute;"
                });
            }
        };
        tipPrototype.anihide = function() {
            var outer = this.getOuter();
            var _this = this;
            var ani = $.core.ani.tween(outer, {
                end: function() {
                    outer.style.display = "none";
                    outer.style.height = _this.tipHeight + "px";
                    conf.hideCallback();
                },
                duration: 300,
                animationType: "easeoutcubic"
            });
            if (conf.direct === "down") {
                ani.play({
                    height: 0
                }, {
                    staticStyle: "overflow:hidden;position:absolute;"
                });
            } else {
                var top = parseInt(outer.style.top, 10) + this.tipHeight;
                ani.play({
                    height: 0,
                    top: top
                }, {
                    staticStyle: "overflow:hidden;position:absolute;"
                });
            }
        };
        document.body.appendChild(box);
        tipPrototype.destroy = function() {
            document.body.removeChild(box);
            tipPrototype = null;
        };
        return tipPrototype;
    };
});;


STK.register("ui.tipAlert", function($) {
    var $easyT = $.core.util.easyTemplate;
    return function(spec) {
        spec = $.parseParam({
            direct: "up",
            className: "WB_widgets W_layer",
            showCallback: $.core.func.empty,
            hideCallback: $.core.func.empty,
            template: '<#et temp data><table cellspacing="0" cellpadding="0" border="0">' + "<tbody><tr><td>" + '<div node-type="msgDiv" class="content layer_mini_info">' + '<p class="clearfix alt_text"><span class="tip_icon WB_tipS_${data.type}"></span>${data.msg}&nbsp; &nbsp; &nbsp; </p>' + "</div>" + "</td></tr></tbody>" + "</table></#et>",
            type: "ok",
            msg: ""
        }, spec);
        var tipAlert = $.ui.tipPrototype(spec);
        var content = tipAlert.getInner();
        var outer = tipAlert.getOuter();
        outer.className = spec.className;
        content.className = "bg";
        var template = spec.template;
        var dom = $.builder($easyT(template, {
            type: spec.type,
            msg: spec.msg
        }).toString());
        tipAlert.setContent(dom.box);
        var tipPrototypeDestroy = tipAlert.destroy;
        tipAlert.destroy = function() {
            tipPrototypeDestroy();
            tipAlert = null;
        };
        return tipAlert;
    };
});;


STK.register("common.widget.reg", function($) {
    var protocol = window.location.protocol == "https:" ? "https:" : "http:";
    var $L = $.kit.extra.language;
    var tip = $.ui.tipAlert({
        className: "WB_tips_top",
        showCallback: function() {
            var box = tip.getOuter();
            box.style.height = "";
            box = null;
        },
        template: '<#et temp data><div class="tips_inner">' + '<span class="WB_tipS_warn"></span><span class="WB_icon_txt">' + $L("#L{您的帐号尚未开通微博，}") + "<a href=" + protocol + '"//weibo.com/signup/full_info.php?appsrc=6cm7D0&backurl=' + encodeURIComponent(document.URL) + '&showlogo=0&vsrc=weiboshow&from=zw" target="_blank">' + $L("#L{立即开通}") + "</a></span>" + "</#et>"
    });
    return function(node) {
        if (!$.isNode(node)) {
            throw "[common.widget.reg] need node as first parameter";
        }
        tip.setLayerXY(node);
        tip.aniShow();
        return tip;
    };
});;


STK.register("common.widget.addFollow", function($) {
    var $L = $.kit.extra.language;
    var $queryToJson = $.core.json.queryToJson;
    var emptyFn = function() {}, args = {
        uid: scope.loginKit().uid,
        url: "",
        fuid: "",
        appsrc: "",
        vsrc: "app_weiboshow",
        success: emptyFn,
        fail: emptyFn,
        btnTemp: ""
    };
    var $followBtn;
    var doPost = function(opts) {
        if (opts.fuid === opts.uid) {
            $followBtn.parentNode.innerHTML = $L('<span class="WB_btnC"><span><em class="WB_btnicn_ok"></em><em>#L{你自己}</em></span></span>');
            return "yourself";
        }
        if (!opts.url) {
            opts.url = "/widget/weiboshow/aj_attention.php";
            if (/weibo.com/.test(location.host)) {
                opts.url = "/weiboshow/aj_attention.php";
            }
        }
        var btnTemp = opts.btnTemp || '<span class="WB_btnC"><span><em class="WB_btnicn_ok"></em><em>#L{已关注}</em></span></span>';
        $.ajax({
            method: "post",
            url: opts.url,
            args: {
                wsrc: $CONFIG.wsrc || "app_weibo_show",
                uid: opts.uid,
                fuid: opts.fuid
            },
            onComplete: function(json) {
                switch (json.code) {
                  case "A00006":
                    break;
                  case "A10007":
                    break;
                  case -1:
                    $.common.widget.reg($followBtn);
                    break;
                  case -2:
                    var login = $.common.widget.login();
                    $.custEvent.add(login, "login", function() {
                        opts.uid = scope.loginKit().uid;
                        doPost(opts);
                    });
                    login.showLogin();
                    break;
                  case -3:
                    break;
                }
                if ((json.code == "A00006" || json.code == "A10007") && $followBtn) {
                    $followBtn.parentNode.innerHTML = $L(btnTemp);
                }
                typeof opts.success === "function" && opts.success(json);
            },
            onFail: function(j) {
                typeof opts.fail === "function" && opts.fail(j);
            }
        });
    };
    var newDoPost = function(node) {
        var nodeData = node.getAttribute("action-data");
        if (!nodeData) {
            return;
        }
        var nodeJson = $queryToJson(nodeData);
        nodeJson.uid && window.open("http://www.weibo.com/u/" + nodeJson.uid + "?refer_flag=2725420000_weiboxiu");
    };
    return function(node, opts) {
        if (!node) {
            throw "[common.widget.addFollow] need node as parameter";
            return;
        }
        $followBtn = node;
        var addFollow = function() {
            if (parent != self && parent != parent.parent) {
                return;
            }
            if (!scope.$isLogin()) {
                var login = $.common.widget.login();
                $.custEvent.add(login, "login", function() {
                    opts.uid = scope.loginKit().uid;
                    newDoPost(node);
                });
                login.showLogin();
                return;
            }
            newDoPost(node);
        };
        var that = {};
        var init = function() {
            opts = $.parseParam(args, opts);
            if (!opts.fuid) {
                opts.fuid = node.getAttribute("uid");
            }
            bindDOM();
        };
        var bindDOM = function() {
            $.addEvent(node, "click", addFollow);
        };
        var destroy = function() {
            $.removeEvent(node, "click", addFollow);
        };
        that.destroy = destroy;
        init();
        return that;
    };
});;






STK.register("comp.widget.show.error", function($) {
    var addEvent = $.addEvent, aBtn = $.E("showTXA"), showTX = $.E("showTX"), showArea = $.E("showBtn");
    var $L = $.kit.extra.language, showTip;
    return function() {
        var that = {};
        if (!aBtn) {
            return that;
        }
        var showTxt = function() {
            showArea.style.display = "none";
            showTX.style.display = "block";
        };
        var doAjax = function() {
            var val = $.E("txContent").value;
            var weiboURL = "/widget/weiboshow/aj_addmblog.php";
            if (/weibo.com/.test(location.host)) {
                weiboURL = "/weiboshow/aj_addmblog.php";
            }
            $.ajax({
                url: weiboURL,
                args: {
                    appkey: $CONFIG.$appsrc,
                    content: encodeURIComponent(val)
                },
                method: "post",
                onComplete: function(json) {
                    var code = json.code;
                    switch (code) {
                      case "A00006":
                        $.E("showTX").innerHTML = $L("#L{提醒成功，辛苦了}");
                        break;
                      case "M01155":
                        alert($L("#L{你刚才好像提醒一次了}"));
                        break;
                      case "M00005":
                        var login = $.common.widget.login();
                        login.showLogin();
                        break;
                      case "M00004":
                        alert($L("#L{参数错误}"));
                        break;
                      case "M00006":
                        alert($L("#L{你未开通微博。}"));
                        break;
                      case "M18003":
                        alert($L("#L{提醒失败}"));
                        break;
                      default:
                        alert($L("#L{提醒失败}"));
                        break;
                    }
                }
            });
        };
        addEvent(aBtn, "click", showTxt);
        addEvent($.E("txBtn"), "click", doAjax);
        var destroy = function() {
            $.removeEvent(aBtn, "click", showTxt);
            $.removeEvent($.E("txBtn"), "click", doAjax);
        };
        that.destroy = destroy;
        return that;
    };
});;


STK.register("comp.widget.show.scroll", function($) {
    var init_scroll, autoScroll;
    var urlSearch = location.search;
    var $wb_list_con = $.E("weibo_list_con"), $wb_list = $.E("weibo_list"), $fanslist = $.E("fans_list_con");
    var sCore = $.core, addEvent = sCore.evt.addEvent, getEvent = sCore.evt.getEvent, fireEvent = sCore.evt.fireEvent, stopEvent = sCore.evt.stopEvent, each = sCore.arr.foreach;
    var _check = function() {};
    var list = null, listMargin = 0;
    var speed = /speed=(\d+)/.test(urlSearch) ? RegExp.$1 : 0;
    var tempSpeed = speed || 5;
    var tempType = "down";
    autoScroll = {
        autoScroll: function(type, speed) {
            var speed = speed || tempSpeed;
            var max = $wb_list.offsetHeight - $wb_list_con.clientHeight;
            clearInterval(this._timer);
            this._timer = setInterval(function() {
                if (!autoScroll.isOutRange) return;
                if (autoScroll.lock) return;
                var st = $wb_list_con.scrollTop;
                st = type == "down" ? Math.min(st + 2, max) : Math.max(st - 2, 0);
                $wb_list_con.scrollTop = st;
                if (st == 0 || st == max) {
                    autoScroll.stop(this._timer);
                }
            }, speed);
        },
        start: function(type, speed) {
            autoScroll.lock = true;
            var speed = speed || tempSpeed;
            tempType = type;
            var max = $wb_list.offsetHeight - $wb_list_con.clientHeight;
            clearInterval(this._timer);
            this._timer = setInterval(function() {
                var st = $wb_list_con.scrollTop;
                st = type === "down" ? Math.min(st + 2, max) : Math.max(st - 2, 0);
                $wb_list_con.scrollTop = st;
                if (st == 0 || st == max) {
                    autoScroll.stop();
                }
            }, speed);
        },
        lock: false,
        isOutRange: true,
        scroll: function(e) {
            clearTimeout(this.ctimer);
            if (autoScroll.isOutRange) return;
            var st = $wb_list_con.scrollTop;
            var max = $wb_list.offsetHeight - $wb_list_con.clientHeight;
            st = e.wheelDelta <= 0 || e.detail > 0 ? Math.min(st + 20, max) : Math.max(st - 20, 0);
            $wb_list_con.scrollTop = st;
            if (st == 0 || st == max) {
                _check();
                return;
            }
            stopEvent(e);
            this.ctimer = setTimeout(function() {
                _check();
            }, 500);
        },
        stop: function(timer) {
            clearInterval(timer || this._timer);
            autoScroll.lock = false;
            _check();
        }
    };
    init_scroll = function() {
        if (!$.E("weibo_con") || $.E("weibo_con").style.display == "none") {
            return;
        }
        $wb_list_con.style.position = "relative";
        $wb_list_con.scrollTop = 0;
        listMargin = $wb_list.offsetTop;
        list = $.sizzle(".weiboShow_mainFeed_list", $wb_list_con);
        (function() {
            var upImg = $.E("weibo_upbtn");
            if (!upImg) {
                return;
            }
            upImg = upImg.getElementsByTagName("em")[0];
            var downImg = $.E("weibo_downbtn").getElementsByTagName("em")[0];
            function ck() {
                var s = $wb_list_con.scrollTop;
                var h = parseInt($wb_list_con.style.height);
                upImg.style.display = s == 0 ? "none" : "";
                downImg.style.display = s + h == $wb_list.offsetHeight ? "none" : "";
            }
            var _timer = null;
            _check = function() {
                clearTimeout(_timer);
                setTimeout(ck, 200);
            };
        })();
        _check();
        if (list.length == 0) {
            return;
        }
        (function() {
            var _timer = null;
            $.addEvent($wb_list_con, "mouseover", function() {
                clearTimeout(_timer);
                autoScroll.isOutRange = false;
                autoScroll.stop();
            });
            $.addEvent($wb_list_con, "mouseout", function(e) {
                clearTimeout(_timer);
                _timer = setTimeout(function() {
                    autoScroll.isOutRange = true;
                    autoScroll.start(tempType);
                }, 50);
            });
        })();
        try {
            window.addEventListener("DOMMouseScroll", function(e) {
                autoScroll.scroll(e || event);
            }, false);
        } catch (err) {
            document.onmousewheel = function(e) {
                autoScroll.scroll(e || event);
            };
        }
        (function() {
            if (speed == 0) return;
            var max = $wb_list.offsetHeight - $wb_list_con.clientHeight;
            $wb_list_con.scrollTop = 0;
            autoScroll.autoScroll("down", +speed);
            setTimeout(function() {
                _check();
            }, +speed);
        })();
        each([ "up", "down" ], function(v, i) {
            addEvent($.E("weibo_" + v + "btn"), "mouseover", function() {
                autoScroll.stop();
            });
            addEvent($.E("weibo_" + v + "btn"), "mouseout", function() {
                autoScroll.start(v);
            });
            addEvent($.E("weibo_" + v + "btn"), "click", function() {
                autoScroll.start(v, 5);
                setTimeout(function() {
                    autoScroll.stop();
                }, 500);
            });
        });
    };
    return function() {
        return {
            init_scroll: init_scroll,
            autoScroll: autoScroll
        };
    };
});;


STK.register("comp.widget.show.style", function($) {
    var sCore = $.core, addEvent = sCore.evt.addEvent, getEvent = sCore.evt.getEvent, trim = sCore.str.trim, reomveEvent = sCore.evt.reomveEvent, sizzle = sCore.dom.sizzle, each = sCore.arr.foreach, fireEvent = sCore.evt.fireEvent, stopEvent = sCore.evt.stopEvent;
    var $wb_list_con = $.E("weibo_list_con"), $wb_list = $.E("weibo_list"), $fanslist = $.E("fans_list_con");
    var urlSearch = location.search;
    var addStyle;
    (function() {
        var isLoaded = false;
        addStyle = function(rules) {
            var styleElement = document.createElement("style");
            styleElement.type = "text/css";
            if ($.IE) {
                styleElement.styleSheet.cssText = rules;
            } else {
                var frag = document.createDocumentFragment();
                frag.appendChild(document.createTextNode(rules));
                styleElement.appendChild(frag);
            }
            function append() {
                document.getElementsByTagName("head")[0].appendChild(styleElement);
            }
            append();
        };
    })();
    var initStyle = function() {
        var colors = /colors=([A-Fa-f\d,]+)/.test(urlSearch) ? RegExp.$1 : "";
        if (colors) {
            colors = colors.split(",");
            var cstr = "";
            if (colors[0]) {
                cstr += ".weiboShow .weiboShow_topborder, .weiboShow .weiboShow_title {background:#" + colors[0] + ";}\n";
            }
            if (colors[1]) {
                cstr += ".weiboShow .weiboShow_wrap { background:#" + colors[1] + " }\n";
            }
            if (colors[2]) {
                cstr += ".weiboShow { color:#" + colors[2] + ";}\n .weiboShow .weiboShow_developerDetail_namedir {color:#" + colors[2] + " }\n";
            }
            if (colors[3]) {
                cstr += ".weiboShow a,\n .weiboShow .WB_linkA a,\n.weiboShow .WB_linkA, \n.weiboShow .WB_linkB a,\n.weiboShow .WB_linkB {color:#" + colors[3] + " }";
            }
            if (colors[4]) {
                cstr += ".weiboShow .weiboShow_mainFeed_list:hover, .weiboShow .weiboShow_mainFeed_list_focus{background:#" + colors[4] + " ;}";
            }
            addStyle(cstr);
        }
        var isborder = /noborder=(\d+)/.test(urlSearch) ? RegExp.$1 : 1;
        if (isborder == 0) {
            $.E("pl_weibo_show").className = "WB_widgets weiboShow weiboShow_noborder";
        }
        try {
            var param = {};
            param.fansRow = /fansRow=(\d+)/.test(urlSearch) ? RegExp.$1 : 2;
            param.isTitle = $.E("weibo_title") ? 1 : 0;
            param.isFans = $fanslist ? 1 : 0;
            param.isWeibo = $.E("weibo_con") ? 1 : 0;
            param.height = parseInt($.E("pl_weibo_show").style.height, 10);
            param.width = $.E("pl_weibo_show").offsetWidth;
        } catch (e) {}
        var maxH = param.height - 30;
        if (param.isTitle == 1) {
            maxH -= 30;
        }
        if ($.E("weibo_head")) {
            maxH -= 86;
        }
        if (maxH < 0) {
            return;
        }
        if (param.isFans) {
            var list = sizzle("li", $fanslist);
            var fash = 0;
            if (list.length == 0) {
                fash = $fanslist.offsetHeight;
            } else {
                var _ul = $fanslist.getElementsByTagName("ul")[0];
                var w = param.width;
                var n = Math.floor((w - 11) / 66);
                if (n == 0) {
                    n = 1;
                }
                var padding = "0 " + (w - 16 - n * 66) / 2 + "px";
                try {
                    _ul.style.padding = padding;
                } catch (e) {
                    var css = $.core.dom.cssText(_ul.style.cssText);
                    css.push("padding", padding);
                    _ul.style.cssText = css.getCss();
                }
                var r = Math.ceil(list.length / n);
                param.fansRow = Math.min(param.fansRow, r, (maxH - 30) / 84 >> 0 || 1);
                fash = param.fansRow * 84;
                if (fash > 0) {
                    fash -= 12;
                }
                fash += 30;
                if (fash >= maxH) {
                    fash = maxH;
                }
                $fanslist.style.height = parseInt(fash - 3) + "px";
            }
            maxH -= fash;
        }
        if (param.isWeibo) {
            if (maxH < 32) {
                $.E("weibo_con").style.display = "none";
                return;
            }
            try {
                var timer = null;
                var doit = function() {
                    var h = $wb_list.offsetHeight;
                    timer && clearInterval(timer);
                    if (h > 0) {
                        var _height;
                        if ($.sizzle(".weiboShow_main_errorBox").length) {
                            _height = (maxH - 20 > h ? maxH - 20 : h) + "px";
                            $wb_list.style.height = _height;
                        } else {
                            _height = (maxH - 20 > h ? h : maxH - 6) + "px";
                        }
                        $wb_list_con.style.height = _height;
                    } else {
                        timer = setInterval(doit, 500);
                    }
                };
                doit();
            } catch (e) {}
        }
    };
    return initStyle;
});;


STK.register("common.listener", function($) {
    var listenerList = {};
    var that = {};
    that.define = function(sChannel, aEventList) {
        if (listenerList[sChannel] != null) {
            throw "common.listener.define: 频道已被占用";
        }
        listenerList[sChannel] = aEventList;
        var ret = {};
        ret.register = function(sEventType, fCallBack) {
            if (listenerList[sChannel] == null) {
                throw "common.listener.define: 频道未定义";
            }
            $.listener.register(sChannel, sEventType, fCallBack);
        };
        ret.fire = function(sEventType, oData) {
            if (listenerList[sChannel] == null) {
                throw "commonlistener.define: 频道未定义";
            }
            $.listener.fire(sChannel, sEventType, oData);
        };
        ret.remove = function(sEventType, fCallBack) {
            $.listener.remove(sChannel, sEventType, fCallBack);
        };
        ret.cache = function(sEventType) {
            return $.listener.cache(sChannel, sEventType);
        };
        return ret;
    };
    return that;
});;


STK.register("common.channel.page", function($) {
    var eventList = [ "resize" ];
    return $.common.listener.define("common.channel.page", eventList);
});;


STK.register("comp.widget.show.resize", function($) {
    return function() {
        var pageSize = {
            page: {
                width: document.body.clientWidth,
                height: document.body.clientHeight
            }
        };
        pageSize = $.jsonToQuery(pageSize.page);
        $.common.channel.page.fire("resize", pageSize);
    };
});;


STK.register("common.xdomain", function($) {
    var win = window, doc = document, count = 0;
    return function(ifr, listener) {
        var that = {};
        if (!(typeof listener === "function")) {
            listener = function() {};
        }
        var sendMessage = function() {
            var hash = "";
            if (win.postMessage) {
                if (win.addEventListener) {
                    win.addEventListener("message", function(e) {
                        listener.call(win, e.data);
                    }, false);
                } else if (win.attachEvent) {
                    win.attachEvent("onmessage", function(e) {
                        listener.call(win, e.data);
                    });
                } else {
                    throw "[common.xDomain] addEventListener error";
                }
                return function(data) {
                    ifr.postMessage(data, "*");
                };
            } else {
                setInterval(function() {
                    if (win.name !== hash) {
                        hash = win.name;
                        listener.call(win, hash);
                    }
                }, 50);
                return function(data) {
                    ifr.name = +(new Date) + count++ + "^" + doc.domain + "&" + escape(data);
                };
            }
        };
        return sendMessage();
    };
});;


STK.register("comp.widget.show.xdomain", function($) {
    var index = 0;
    return function(node) {
        var that = {
            setSize: $.common.xdomain(node)
        };
        var init = function() {
            node = node || parent;
            var a = {
                page: {
                    width: document.body.clientWidth,
                    height: document.body.clientHeight
                }
            };
            a = $.jsonToQuery(a.page);
            setInterval(function() {
                if (index < 4) {
                    that.setSize(a);
                }
                index++;
            }, 200);
        };
        that.resize = function(size) {
            if (index < 4) {
                setTimeout(function() {
                    that.resize(size);
                }, 200);
                return;
            }
            var a = size || {
                page: {
                    width: document.body.clientWidth,
                    height: document.body.clientHeight
                }
            };
            a = $.jsonToQuery(a);
            that.setSize(a);
        };
        var destroy = function() {};
        that.destroy = destroy;
        init();
        return that;
    };
});;




STK.register("core.dom.isNode", function($) {
    return function(node) {
        return node != undefined && Boolean(node.nodeName) && Boolean(node.nodeType);
    };
});;


STK.register("core.arr.isArray", function($) {
    return function(o) {
        return Object.prototype.toString.call(o) === "[object Array]";
    };
});;


STK.register("core.evt.custEvent", function($) {
    var _custAttr = "__custEventKey__", _custKey = 1, _custCache = {}, _findObj = function(obj, type) {
        var _key = typeof obj == "number" ? obj : obj[_custAttr];
        return _key && _custCache[_key] && {
            obj: typeof type == "string" ? _custCache[_key][type] : _custCache[_key],
            key: _key
        };
    };
    return {
        define: function(obj, type) {
            if (obj && type) {
                var _key = typeof obj == "number" ? obj : obj[_custAttr] || (obj[_custAttr] = _custKey++), _cache = _custCache[_key] || (_custCache[_key] = {});
                type = [].concat(type);
                for (var i = 0; i < type.length; i++) {
                    _cache[type[i]] || (_cache[type[i]] = []);
                }
                return _key;
            }
        },
        undefine: function(obj, type) {
            if (obj) {
                var _key = typeof obj == "number" ? obj : obj[_custAttr];
                if (_key && _custCache[_key]) {
                    if (type) {
                        type = [].concat(type);
                        for (var i = 0; i < type.length; i++) {
                            if (type[i] in _custCache[_key]) delete _custCache[_key][type[i]];
                        }
                    } else {
                        delete _custCache[_key];
                    }
                }
            }
        },
        add: function(obj, type, fn, data) {
            if (obj && typeof type == "string" && fn) {
                var _cache = _findObj(obj, type);
                if (!_cache || !_cache.obj) {
                    throw "custEvent (" + type + ") is undefined !";
                }
                _cache.obj.push({
                    fn: fn,
                    data: data
                });
                return _cache.key;
            }
        },
        once: function(obj, type, fn, data) {
            if (obj && typeof type == "string" && fn) {
                var _cache = _findObj(obj, type);
                if (!_cache || !_cache.obj) {
                    throw "custEvent (" + type + ") is undefined !";
                }
                _cache.obj.push({
                    fn: fn,
                    data: data,
                    once: true
                });
                return _cache.key;
            }
        },
        remove: function(obj, type, fn) {
            if (obj) {
                var _cache = _findObj(obj, type), _obj, index;
                if (_cache && (_obj = _cache.obj)) {
                    if ($.core.arr.isArray(_obj)) {
                        if (fn) {
                            var i = 0;
                            while (_obj[i]) {
                                if (_obj[i].fn === fn) {
                                    break;
                                }
                                i++;
                            }
                            _obj.splice(i, 1);
                        } else {
                            _obj.splice(0, _obj.length);
                        }
                    } else {
                        for (var i in _obj) {
                            _obj[i] = [];
                        }
                    }
                    return _cache.key;
                }
            }
        },
        fire: function(obj, type, args) {
            if (obj && typeof type == "string") {
                var _cache = _findObj(obj, type), _obj;
                if (_cache && (_obj = _cache.obj)) {
                    if (!$.core.arr.isArray(args)) {
                        args = args != undefined ? [ args ] : [];
                    }
                    for (var i = _obj.length - 1; i > -1 && _obj[i]; i--) {
                        var fn = _obj[i].fn;
                        var isOnce = _obj[i].once;
                        if (fn && fn.apply) {
                            try {
                                fn.apply(obj, [ {
                                    type: type,
                                    data: _obj[i].data
                                } ].concat(args));
                                if (isOnce) {
                                    _obj.splice(i, 1);
                                }
                            } catch (e) {
                                $.log("[error][custEvent]" + e.message);
                            }
                        }
                    }
                    return _cache.key;
                }
            }
        },
        destroy: function() {
            _custCache = {};
            _custKey = 1;
        }
    };
});;


STK.register("core.util.browser", function($) {
    var ua = navigator.userAgent.toLowerCase();
    var external = window.external || "";
    var core, m, extra, version, os;
    var numberify = function(s) {
        var c = 0;
        return parseFloat(s.replace(/\./g, function() {
            return c++ == 1 ? "" : ".";
        }));
    };
    try {
        if (/windows|win32/i.test(ua)) {
            os = "windows";
        } else if (/macintosh/i.test(ua)) {
            os = "macintosh";
        } else if (/rhino/i.test(ua)) {
            os = "rhino";
        }
        if ((m = ua.match(/applewebkit\/([^\s]*)/)) && m[1]) {
            core = "webkit";
            version = numberify(m[1]);
        } else if ((m = ua.match(/presto\/([\d.]*)/)) && m[1]) {
            core = "presto";
            version = numberify(m[1]);
        } else if (m = ua.match(/msie\s([^;]*)/)) {
            core = "trident";
            version = 1;
            if ((m = ua.match(/trident\/([\d.]*)/)) && m[1]) {
                version = numberify(m[1]);
            }
        } else if (/gecko/.test(ua)) {
            core = "gecko";
            version = 1;
            if ((m = ua.match(/rv:([\d.]*)/)) && m[1]) {
                version = numberify(m[1]);
            }
        }
        if (/world/.test(ua)) {
            extra = "world";
        } else if (/360se/.test(ua)) {
            extra = "360";
        } else if (/maxthon/.test(ua) || typeof external.max_version == "number") {
            extra = "maxthon";
        } else if (/tencenttraveler\s([\d.]*)/.test(ua)) {
            extra = "tt";
        } else if (/se\s([\d.]*)/.test(ua)) {
            extra = "sogou";
        }
    } catch (e) {}
    var ret = {
        OS: os,
        CORE: core,
        Version: version,
        EXTRA: extra ? extra : false,
        IE: /msie/.test(ua),
        OPERA: /opera/.test(ua),
        MOZ: /gecko/.test(ua) && !/(compatible|webkit)/.test(ua),
        IE5: /msie 5 /.test(ua),
        IE55: /msie 5.5/.test(ua),
        IE6: /msie 6/.test(ua),
        IE7: /msie 7/.test(ua),
        IE8: /msie 8/.test(ua),
        IE9: /msie 9/.test(ua),
        SAFARI: !/chrome\/([\d.]*)/.test(ua) && /\/([\d.]*) safari/.test(ua),
        CHROME: /chrome\/([\d.]*)/.test(ua),
        IPAD: /\(ipad/i.test(ua),
        IPHONE: /\(iphone/i.test(ua),
        ITOUCH: /\(itouch/i.test(ua),
        MOBILE: /mobile/i.test(ua)
    };
    return ret;
});;


STK.register("core.evt.getEvent", function($) {
    return function() {
        if ($.IE) {
            return window.event;
        } else {
            if (window.event) {
                return window.event;
            }
            var o = arguments.callee.caller;
            var e;
            var n = 0;
            while (o != null && n < 40) {
                e = o.arguments[0];
                if (e && (e.constructor == Event || e.constructor == MouseEvent || e.constructor == KeyboardEvent)) {
                    return e;
                }
                n++;
                o = o.caller;
            }
            return e;
        }
    };
});;


STK.register("core.evt.fixEvent", function($) {
    return function(e) {
        e = e || $.core.evt.getEvent();
        if (!e.target) {
            e.target = e.srcElement;
            e.pageX = e.x;
            e.pageY = e.y;
        }
        if (typeof e.layerX == "undefined") e.layerX = e.offsetX;
        if (typeof e.layerY == "undefined") e.layerY = e.offsetY;
        return e;
    };
});;


STK.register("core.util.scrollPos", function($) {
    return function(oDocument) {
        oDocument = oDocument || document;
        var dd = oDocument.documentElement;
        var db = oDocument.body;
        return {
            top: Math.max(window.pageYOffset || 0, dd.scrollTop, db.scrollTop),
            left: Math.max(window.pageXOffset || 0, dd.scrollLeft, db.scrollLeft)
        };
    };
});;


STK.register("kit.util.drag", function($) {
    var stopClick = function(e) {
        e.cancelBubble = true;
        return false;
    };
    var getParams = function(args, evt) {
        args["clientX"] = evt.clientX;
        args["clientY"] = evt.clientY;
        args["pageX"] = evt.clientX + $.core.util.scrollPos()["left"];
        args["pageY"] = evt.clientY + $.core.util.scrollPos()["top"];
        args["offsetX"] = evt.offsetX || evt.layerX;
        args["offsetY"] = evt.offsetY || evt.layerY;
        args["target"] = evt.target || evt.srcElement;
        return args;
    };
    return function(actEl, spec) {
        if (!$.core.dom.isNode(actEl)) {
            throw "core.util.drag need Element as first parameter";
        }
        var conf = $.core.obj.parseParam({
            actRect: [],
            actObj: {}
        }, spec);
        var that = {};
        var dragStartKey = $.core.evt.custEvent.define(conf.actObj, "dragStart");
        var dragEndKey = $.core.evt.custEvent.define(conf.actObj, "dragEnd");
        var dragingKey = $.core.evt.custEvent.define(conf.actObj, "draging");
        var startFun = function(e) {
            var args = getParams({}, e);
            document.body.onselectstart = function() {
                return false;
            };
            $.core.evt.addEvent(document, "mousemove", dragFun);
            $.core.evt.addEvent(document, "mouseup", endFun);
            $.core.evt.addEvent(document, "click", stopClick, true);
            if (!$.IE) {
                e.preventDefault();
                e.stopPropagation();
            }
            $.core.evt.custEvent.fire(dragStartKey, "dragStart", args);
            return false;
        };
        var dragFun = function(e) {
            var args = getParams({}, e);
            e.cancelBubble = true;
            $.core.evt.custEvent.fire(dragStartKey, "draging", args);
        };
        var endFun = function(e) {
            var args = getParams({}, e);
            document.body.onselectstart = function() {
                return true;
            };
            $.core.evt.removeEvent(document, "mousemove", dragFun);
            $.core.evt.removeEvent(document, "mouseup", endFun);
            $.core.evt.removeEvent(document, "click", stopClick, true);
            $.core.evt.custEvent.fire(dragStartKey, "dragEnd", args);
        };
        $.core.evt.addEvent(actEl, "mousedown", startFun);
        that.destroy = function() {
            $.core.evt.removeEvent(actEl, "mousedown", startFun);
            conf = null;
        };
        that.getActObj = function() {
            return conf.actObj;
        };
        return that;
    };
});;




STK.register("common.widget.dragScroll", function($) {
    var that = {}, addEvent = $.core.evt.addEvent, custEvent = $.core.evt.custEvent;
    return function(spec) {
        var contentOuter, contentInner, dragOuter, dragDiv, contentOrgPos, dragOuterOrgPos, dragOrgPos, offsetY, dragHeight, dragTop, isMobile = false;
        var opt = {
            contentOuter: null,
            contentInner: null,
            dragOuter: null,
            dragInner: null,
            dragInnerMinHeight: null
        };
        opt = $.parseParam(opt, spec);
        var dragOuterClickHandler = function(evt) {
            var evt = evt || window.event;
            var target = evt.target || evt.srcElement;
            dragOuterOrgPos = $.core.dom.position(dragOuter);
            var currentTop = evt.clientY - dragOuterOrgPos.t, cTop;
            if (target == dragDiv) {
                return;
            }
            cTop = parseInt(currentTop * contentInner.offsetHeight / dragOuter.offsetHeight, 10);
            if (cTop >= Math.abs(contentOuter.offsetHeight - contentInner.offsetHeight)) {
                cTop = contentInner.offsetHeight - contentOuter.offsetHeight;
            }
            if (currentTop < 0) {
                return;
            }
            if (currentTop + dragDiv.offsetHeight > dragOuter.offsetHeight) {
                currentTop = dragOuter.offsetHeight - dragDiv.offsetHeight;
            }
            if (cTop >= Math.abs(contentOuter.offsetHeight - contentInner.offsetHeight)) {
                cTop = contentInner.offsetHeight - contentOuter.offsetHeight;
            }
            dragDiv.style.top = currentTop + "px";
            contentInner.style.marginTop = -1 * cTop + "px";
        };
        var scrollFun = function(evt) {
            $.core.evt.stopEvent(evt);
            var ord = evt.wheelDelta / 120 || evt.detail / -3, dis;
            if (Math.abs(ord) > 1) return;
            if (ord > 0 && contentInner.offsetTop >= 0) {
                dis = 0;
                return;
            } else if (ord < 0 && contentInner.offsetTop <= contentOuter.offsetHeight - contentInner.offsetHeight) {
                dis = 0;
                return;
            }
            dis = ord * 40;
            if (ord > 0 && Math.abs(contentInner.offsetTop) < dis) {
                dis = ord * Math.abs(contentInner.offsetTop);
            }
            if (ord < 0 && Math.abs(contentInner.offsetTop - (contentOuter.offsetHeight - contentInner.offsetHeight)) < Math.abs(dis)) {
                dis = ord * Math.abs(contentInner.offsetTop - (contentOuter.offsetHeight - contentInner.offsetHeight));
            }
            elmMove(dis, ord);
        };
        var elmMove = function(dis, ord) {
            var currentTop, dragTop;
            currentTop = contentInner.offsetTop + dis;
            contentInner.style.marginTop = currentTop + "px";
            dragTop = Math.round(currentTop * dragOuter.offsetHeight / contentInner.offsetHeight);
            dragDiv.style.top = -1 * dragTop + "px";
            if (contentInner.offsetTop >= 0) {
                dragDiv.style.top = "0px";
            } else if (contentInner.offsetTop <= contentOuter.offsetHeight - contentInner.offsetHeight) {
                dragDiv.style.top = dragOuter.offsetHeight - dragDiv.offsetHeight + "px";
            }
        };
        var dragHandlers = {
            dragStart: function(e, data) {
                offsetY = data.offsetY;
            },
            draging: function(e, data) {
                var dis, currentTop, cTop;
                var scrollPos = $.core.util.scrollPos();
                currentTop = data.clientY - offsetY - dragOrgPos.t + scrollPos.top;
                if (currentTop < 0) {
                    contentInner.style.marginTop = "0px";
                    return;
                }
                if (currentTop + dragDiv.offsetHeight > dragOuter.offsetHeight) {
                    contentInner.style.marginTop = contentOuter.offsetHeight - contentInner.offsetHeight + "px";
                    return;
                }
                cTop = parseInt(currentTop * contentInner.offsetHeight / dragOuter.offsetHeight, 10);
                if (cTop >= Math.abs(contentOuter.offsetHeight - contentInner.offsetHeight)) {
                    return;
                }
                dragDiv.style.top = currentTop + "px";
                contentInner.style.marginTop = -1 * cTop + "px";
            },
            dragEnd: function(e, data) {},
            dragMove: function(dis) {
                var currentTop;
                currentTop = contentInner.offsetTop + dis - contentOrgPos.t;
                contentInner.style.marginTop = currentTop + "px";
            }
        };
        var outerMouseOverHandler = function(evt) {
            if (document.attachEvent) {
                contentOuter.attachEvent("onmousewheel", scrollFun);
            }
            if (document.addEventListener) {
                contentOuter.addEventListener("mousewheel", scrollFun, false);
                contentOuter.addEventListener("DOMMouseScroll", scrollFun, false);
            }
        };
        var outerMouseOutHandler = function(evt) {
            if (document.attachEvent) {
                contentOuter.detachEvent("onmousewheel", scrollFun);
            }
            if (document.addEventListener) {
                contentOuter.removeEventListener("mousewheel", scrollFun, false);
                contentOuter.removeEventListener("DOMMouseScroll", scrollFun, false);
            }
        };
        var destroy = function() {
            outerMouseOutHandler();
            custEvent.remove(drag.getActObj(), "dragStart", dragHandlers.dragStart);
            custEvent.remove(drag.getActObj(), "draging", dragHandlers.draging);
        };
        var reset = function() {
            if (isMobile) {
                contentInner.style.height = contentOuter.offsetHeight + "px";
                contentInner.style.minHeight = "";
                contentInner.style.overflowY = "scroll";
                dragOuter.style.display = "none";
                dragDiv.style.display = "none";
                destroy();
                return;
            }
            if (contentInner.offsetHeight <= contentOuter.offsetHeight) {
                contentInner.style.marginTop = "0px";
                dragDiv.style.height = "0px";
                dragOuter.style.display = "none";
                destroy();
                return;
            }
            var cTop;
            dragOuter.style.display = "block";
            contentOrgPos = $.core.dom.position(contentOuter);
            dragHeight = parseInt(contentOuter.offsetHeight * dragOuter.offsetHeight / contentInner.offsetHeight, 10);
            dragDiv.style.height = dragHeight + "px";
            cTop = -1 * opt.contentInner.offsetTop * opt.dragOuter.offsetHeight / opt.contentInner.offsetHeight;
            opt.dragInner.style.top = cTop + "px";
            dragOuterOrgPos = $.core.dom.position(dragOuter);
            if (contentInner.offsetTop <= contentOuter.offsetHeight - contentInner.offsetHeight) {
                contentInner.style.marginTop = contentOuter.offsetHeight - contentInner.offsetHeight + "px";
                dragDiv.style.top = dragOuter.offsetHeight - dragDiv.offsetHeight + "px";
            }
            outerMouseOutHandler();
            outerMouseOverHandler();
        };
        var argsCheck = function() {
            if (opt.contentOuter == null || opt.contentInner == null || opt.dragOuter == null || opt.dragInner == null) {
                throw "node is node defined";
            }
        };
        var parseDOM = function() {
            contentOuter = opt.contentOuter;
            contentInner = opt.contentInner;
            dragOuter = opt.dragOuter;
            dragDiv = opt.dragInner;
        };
        var bindDOM = function() {
            drag = $.kit.util.drag(dragDiv);
            outerMouseOverHandler();
            addEvent(dragOuter, "click", dragOuterClickHandler);
            custEvent.add(drag.getActObj(), "dragStart", dragHandlers.dragStart);
            custEvent.add(drag.getActObj(), "draging", dragHandlers.draging);
        };
        var initPlugins = function() {
            var broswer = $.core.util.browser;
            isMobile = broswer.MOBILE;
            if (isMobile) {
                contentInner.style.height = contentOuter.offsetHeight + "px";
                contentInner.style.minHeight = "";
                contentInner.style.overflowY = "scroll";
                dragOuter.style.display = "none";
                dragDiv.style.display = "none";
                destroy();
                return;
            }
            if (contentInner.offsetHeight <= contentOuter.offsetHeight) {
                dragDiv.style.height = "0px";
                dragOuter.style.display = "none";
                destroy();
                return;
            }
            dragOuter.style.display = "block";
            contentInner.style.marginTop = "0px";
            dragDiv.style.top = "0px";
            contentOrgPos = $.core.dom.position(contentOuter);
            dragOuterOrgPos = $.core.dom.position(dragOuter);
            dragOrgPos = $.core.dom.position(dragDiv);
            dragHeight = Math.round(contentOuter.offsetHeight * dragOuter.offsetHeight / contentInner.offsetHeight);
            if (opt.dragInnerMinHeight) {
                dragHeight = dragHeight > opt.dragInnerMinHeight ? dragHeight : opt.dragInnerMinHeight;
            }
            dragDiv.style.height = dragHeight + "px";
            dragTop = dragDiv.offsetTop;
        };
        var init = function() {
            argsCheck();
            parseDOM();
            bindDOM();
            initPlugins();
        };
        init();
        that.elmMove = elmMove;
        that.init = initPlugins;
        that.destroy = destroy;
        that.reset = reset;
        return that;
    };
});;




if (typeof App === "undefined") {
    App = {};
}

if (typeof scope === "undefined") {
    scope = $CONFIG;
}

STK.register("comp.widget.show.init", function($) {
    var sCore = $.core, addEvent = sCore.evt.addEvent, getEvent = sCore.evt.getEvent, trim = sCore.str.trim, reomveEvent = sCore.evt.reomveEvent, sizzle = sCore.dom.sizzle, ajax = sCore.io.ajax, each = sCore.arr.foreach, fireEvent = sCore.evt.fireEvent, stopEvent = sCore.evt.stopEvent, $L = $.kit.extra.language;
    var Scroll = $.comp.widget.show.scroll();
    var init_scroll = Scroll.init_scroll, autoScroll = Scroll.autoScroll;
    var urlSearch = location.search;
    var $wb_list_con = $.E("weibo_list_con"), $wb_list = $.E("weibo_list"), $fanslist = $.E("fans_list_con");
    var fbtn = '<cite class="WB_follow_status"><cite class="WB_follow_status_inner"><cite class="WB_follow_box"><u class="WB_icon_followed"></u>#L{已关注} </cite></cite></cite>';
    var urlObj = $.core.util.URL(document.location.href);
    var xdomain;
    return function(node, opts) {
        var that = {};
        var iScroll;
        var logInit = function() {
            var imgPV = new Image;
            var url = "//rs.sinajs.cn/tmp.gif?";
            url += "id=show&action=pv";
            url += "&uid=" + ($CONFIG.$uid || 0);
            url += "&url=" + encodeURIComponent(document.referrer);
            url += "&r=" + (new Date).valueOf();
            imgPV.src = url;
        };
        var resizeHeight = function() {
            var pageSize = $.pageSize();
            pageSize.page.height = $.core.dom.getSize(node).height;
            var size = pageSize.page;
            xdomain.resize(size);
        };
        var init = function() {
            $.comp.widget.show.style();
            bindDOM();
            logInit();
            if ($.E("scrollCon")) {
                iScroll = $.common.widget.dragScroll({
                    contentOuter: $.E("weibo_list_con"),
                    contentInner: $.E("weibo_list"),
                    dragOuter: $.E("scrollCon"),
                    dragInner: $.E("scrollBar"),
                    dragInnerMinHeight: 20
                });
            } else {
                init_scroll();
            }
            if (scope.$isBD) {
                xdomain = $.comp.widget.show.xdomain(window.parent || window.self);
                bindListener();
                resizeHeight();
            }
        };
        var bindDOM = function() {
            var $followBtn = $.E("followBtn");
            var opts = {
                uid: scope.$uid
            };
            if (urlObj.getParam("followbtn") == 1) {
                opts["btnTemp"] = fbtn;
            }
            $followBtn && $.common.widget.addFollow($followBtn, opts);
            $.comp.widget.show.error();
        };
        var bindListener = function() {
            $.common.channel.page.register("resize", xdomain.setSize);
        };
        var destroy = function() {
            each([ "up", "down" ], function(v, i) {
                removeEvent($.E("weibo_" + v + "btn"), "mouseover", function() {
                    autoScroll.start(v);
                });
                removeEvent($.E("weibo_" + v + "btn"), "mouseout", function() {
                    autoScroll.stop();
                });
            });
        };
        init();
        that.destroy = destroy;
        return that;
    };
});;


STK.pageletM.register("pl.widget.show", function($) {
    try {
        var opts = {};
        var node = $.E("pl_weibo_show");
        var that = $.comp.widget.show.init(node, opts);
        return that;
    } catch (e) {}
});;


STK.pageletM.start();;
