package com.eia.ui.controller;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
public class AppPageController {

    @GetMapping("/logout-success")
    public String logoutSuccess() {
        return "logout-success";
    }
}
